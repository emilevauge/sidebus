import Foundation
import Security

/// Empreintes des certificats des tablettes appairées.
///
/// Modèle `known_hosts` : une entrée par appareil, la clé étant son identifiant
/// persistant. Une empreinte qui change pour un appareil connu est un refus, pas une
/// question.
///
/// Le stockage passe par le **trousseau à protection de données**, et non par le trousseau
/// historique. Dans celui ci, l'autorisation d'accès est liée au binaire qui a écrit
/// l'entrée : après une recompilation, la moindre lecture ouvre une demande d'accès
/// modale, qui fige l'application au milieu d'un handshake TLS. Le trousseau à protection
/// de données range les entrées par identité de signature, sans dialogue.
///
/// Quand il n'est pas disponible, faute d'entitlement d'identifiant d'application, on
/// retombe sur un fichier de l'espace de l'application. Ces empreintes ne sont pas des
/// secrets : ce sont des données d'intégrité, publiques par nature, et le fichier est
/// lisible du seul utilisateur.
public struct PairingStore: Sendable {

    /// Entrées de l'application. Les tests utilisent leur propre service, sinon ils
    /// énumèrent les entrées créées par l'app signée et macOS demande une autorisation,
    /// ce qui bloque la suite.
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
                return "trousseau inaccessible (OSStatus \(status))"
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
        // Entrée absente du trousseau : elle peut venir du repli fichier, écrit quand le
        // trousseau à protection de données n'était pas accessible.
        return fileStore.read(account: account)
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            // Trousseau moderne : pas d'ACL par binaire, donc pas de dialogue.
            kSecUseDataProtectionKeychain as String: true,
        ]
    }

    /// Le trousseau à protection de données exige une identité d'application. Une app
    /// signée localement n'en a pas toujours : on bascule alors sur le fichier.
    private func isUnavailable(_ status: OSStatus) -> Bool {
        status == errSecMissingEntitlement || status == errSecNotAvailable || status == -34018
    }

    private var fileStore: FingerprintFile { FingerprintFile(service: service) }

    /// Compte de l'index inverse, qui évite d'énumérer le trousseau.
    ///
    /// Énumérer fait toucher des entrées écrites par d'autres identités de code, par
    /// exemple après un changement de signature, et macOS ouvre alors une demande d'accès
    /// qui bloque l'application. Une lecture directe ne touche qu'une entrée.
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

    /// Toutes les entrées, par identifiant d'appareil. Réservé au diagnostic : le chemin
    /// courant passe par des lectures directes.
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

    /// Vrai si cette empreinte est déjà appairée, quel que soit l'appareil.
    ///
    /// Sert au cas USB : l'identifiant de l'appareil n'est connu qu'après DEVICE_INFO,
    /// donc après le handshake TLS. L'empreinte, elle, est disponible tout de suite.
    public func isKnown(_ fingerprint: Data) -> Bool {
        deviceID(for: fingerprint) != nil
    }

    /// Identifiant associé à une empreinte, par lecture directe de l'index inverse.
    public func deviceID(for fingerprint: Data) -> String? {
        guard let data = read(account: reverseAccount(for: fingerprint)) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}


/// Repli fichier, quand le trousseau à protection de données n'est pas accessible.
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
        // Pas de `completeFileProtection` : c'est une option iOS, macOS la refuse.
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
}
