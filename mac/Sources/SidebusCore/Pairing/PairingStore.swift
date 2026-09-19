import Foundation
import Security

/// Certificate fingerprints of the paired tablets.
///
/// The `known_hosts` model: one entry per device, keyed by its persistent identifier. A
/// fingerprint that changes for a known device is a refusal, not a question.
///
/// Storage goes through the **data protection keychain**, not the legacy one. In the legacy
/// keychain, access is tied to the binary that wrote the entry: after a rebuild, the
/// slightest read opens a modal access prompt, which freezes the app in the middle of a TLS
/// handshake. The data protection keychain files entries by signing identity, with no
/// dialog.
///
/// When it is unavailable, for want of an application identifier entitlement, we fall back
/// to a file in the application's own space. These fingerprints are not secrets: they are
/// integrity data, public by nature, and the file is readable by the user alone.
public struct PairingStore: Sendable {

    /// The application's entries. The tests use a service of their own, otherwise they
    /// enumerate entries written by the signed app, macOS asks for authorisation, and
    /// everything stalls.
    public static let shared = PairingStore(service: "app.sidebus.pairing")

    public let service: String

    public init(service: String) {
        self.service = service
    }

    public enum StoreError: Error, CustomStringConvertible, Sendable {
        case keychainFailed(OSStatus)

        public var description: String {
            switch self {
            case let .keychainFailed(status):
                return "keychain unreachable (OSStatus \(status))"
            }
        }
    }

    public func fingerprint(forDeviceID deviceID: String) -> Data? {
        read(account: deviceID)
    }

    private func read(account: String) -> Data? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess, let data = result as? Data { return data }
        // Entry missing from the keychain: it may come from the file fallback, written when
        // the data protection keychain was not reachable.
        return fileStore.read(account: account)
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            // Modern keychain: no per binary ACL, so no dialog.
            kSecUseDataProtectionKeychain as String: true,
        ]
    }

    /// The data protection keychain demands an application identity. A locally signed app
    /// does not always have one, so we switch to the file.
    private func isUnavailable(_ status: OSStatus) -> Bool {
        status == errSecMissingEntitlement || status == errSecNotAvailable || status == -34018
    }

    private var fileStore: FingerprintFile { FingerprintFile(service: service) }

    /// Account of the reverse index, which avoids enumerating the keychain.
    ///
    /// Enumerating touches entries written by other code identities, after a signature
    /// change for instance, and macOS then opens an access prompt that blocks the app. A
    /// direct read touches one entry only.
    private func reverseAccount(for fingerprint: Data) -> String {
        "fp-" + fingerprint.map { String(format: "%02x", $0) }.joined()
    }

    public func save(_ fingerprint: Data, forDeviceID deviceID: String) throws {
        try write(fingerprint, account: deviceID)
        try write(Data(deviceID.utf8), account: reverseAccount(for: fingerprint))
    }

    private func write(_ value: Data, account: String) throws {
        let query = baseQuery(account: account)

        let status = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: value] as CFDictionary
        )
        if status == errSecSuccess { return }

        if isUnavailable(status) {
            try fileStore.write(value, account: account)
            return
        }
        guard status == errSecItemNotFound else { throw StoreError.keychainFailed(status) }

        var item = query
        item[kSecValueData as String] = value
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        if addStatus == errSecSuccess { return }
        if isUnavailable(addStatus) {
            try fileStore.write(value, account: account)
            return
        }
        throw StoreError.keychainFailed(addStatus)
    }

    public func remove(deviceID: String) {
        if let fingerprint = fingerprint(forDeviceID: deviceID) {
            delete(account: reverseAccount(for: fingerprint))
        }
        delete(account: deviceID)
    }

    private func delete(account: String) {
        SecItemDelete(baseQuery(account: account) as CFDictionary)
        fileStore.delete(account: account)
    }

    /// Every entry, by device identifier. Diagnostics only: the normal path goes through
    /// direct reads.
    public func all() -> [String: Data] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecUseDataProtectionKeychain as String: true,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
            let items = result as? [[String: Any]]
        else { return [:] }

        var entries: [String: Data] = [:]
        for item in items {
            guard let account = item[kSecAttrAccount as String] as? String,
                let data = fingerprint(forDeviceID: account)
            else { continue }
            entries[account] = data
        }
        return entries
    }

    /// Forgets every paired device. The next link will ask for a code again.
    public func removeAll() {
        for account in all().keys {
            remove(deviceID: account)
        }
        // The keychain may hold orphaned reverse index entries, and the fallback file its own
        // copy: sweep both.
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecUseDataProtectionKeychain as String: true,
        ] as CFDictionary)
        fileStore.removeAll()
    }

    /// True when this fingerprint is already paired, whatever the device.
    ///
    /// Serves the USB case: the device identifier is only known after DEVICE_INFO, so
    /// after the TLS handshake. The fingerprint is available right away.
    public func isKnown(_ fingerprint: Data) -> Bool {
        deviceID(for: fingerprint) != nil
    }

    /// Identifier tied to a fingerprint, by a direct read of the reverse index.
    public func deviceID(for fingerprint: Data) -> String? {
        guard let data = read(account: reverseAccount(for: fingerprint)) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}


/// File fallback, when the data protection keychain is not reachable.
private struct FingerprintFile {
    let service: String

    private var url: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Sidebus", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: base,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        return base.appendingPathComponent("\(service).plist")
    }

    private func load() -> [String: Data] {
        guard let data = try? Data(contentsOf: url),
            let entries = try? PropertyListSerialization.propertyList(
                from: data,
                format: nil
            ) as? [String: Data]
        else { return [:] }
        return entries
    }

    private func save(_ entries: [String: Data]) throws {
        let data = try PropertyListSerialization.data(
            fromPropertyList: entries,
            format: .binary,
            options: 0
        )
        // No `completeFileProtection`: that is an iOS option, macOS refuses it.
        try data.write(to: url, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    func read(account: String) -> Data? {
        load()[account]
    }

    func write(_ value: Data, account: String) throws {
        var entries = load()
        entries[account] = value
        try save(entries)
    }

    func delete(account: String) {
        var entries = load()
        entries.removeValue(forKey: account)
        try? save(entries)
    }

    func removeAll() {
        try? FileManager.default.removeItem(at: url)
    }
}
