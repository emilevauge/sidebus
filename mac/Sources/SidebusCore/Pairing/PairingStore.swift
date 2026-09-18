import Foundation
import Security

/// Empreintes des certificats des tablettes appairées, dans le trousseau.
///
/// Modèle `known_hosts` : une entrée par appareil, la clé étant son identifiant
/// persistant. Une empreinte qui change pour un appareil connu est un refus, pas une
/// question.
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
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else {
            return nil
        }
        return result as? Data
    }

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
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]

        let status = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: value] as CFDictionary
        )
        if status == errSecSuccess { return }

        guard status == errSecItemNotFound else { throw StoreError.keychainFailed(status) }

        var item = query
        item[kSecValueData as String] = value
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw StoreError.keychainFailed(addStatus) }
    }

    public func remove(deviceID: String) {
        if let fingerprint = fingerprint(forDeviceID: deviceID) {
            delete(account: reverseAccount(for: fingerprint))
        }
        delete(account: deviceID)
    }

    private func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }

    /// Toutes les entrées, par identifiant d'appareil.
    ///
    /// En deux temps : la liste des comptes, puis la donnée de chacun. Le trousseau de
    /// macOS ne renvoie pas les données sur une requête à résultats multiples.
    public func all() -> [String: Data] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
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
