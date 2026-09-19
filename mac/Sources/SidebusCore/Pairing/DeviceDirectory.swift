import Foundation

/// Un appareil appairé, tel que le menu et les réglages l'affichent.
///
/// L'empreinte du certificat vit dans `PairingStore`, pas ici : ce sont deux choses de
/// nature différente. L'empreinte est une donnée d'intégrité, qui décide d'accepter ou de
/// refuser un lien. Ce qui suit n'est que de l'affichage et du confort, et se perd sans
/// conséquence.
public struct PairedDevice: Codable, Sendable, Hashable, Identifiable {
    public var id: String { deviceID }

    /// Identifiant persistant de la tablette, en forme texte. C'est la clé de tout.
    public let deviceID: String
    public var name: String

    /// Dernier transport par lequel on l'a vue, pour l'afficher hors ligne.
    public var lastTransport: TransportKind?
    public var lastSeen: Date

    /// Vrai si le partage vers cet appareil doit reprendre tout seul quand il réapparaît.
    /// Mis à vrai en démarrant le partage, à faux en l'arrêtant.
    public var resumesSharing: Bool

    public init(
        deviceID: String,
        name: String,
        lastTransport: TransportKind? = nil,
        lastSeen: Date = Date(),
        resumesSharing: Bool = false
    ) {
        self.deviceID = deviceID
        self.name = name
        self.lastTransport = lastTransport
        self.lastSeen = lastSeen
        self.resumesSharing = resumesSharing
    }
}

extension TransportKind: Codable {}

/// Les appareils appairés, rangés par identifiant.
///
/// Stocké dans les préférences, en JSON. Rien ici n'est secret, et perdre le fichier ne
/// casse pas l'appairage : les empreintes restent dans le trousseau, seuls les noms et la
/// reprise automatique disparaissent.
public struct DeviceDirectory: @unchecked Sendable {
    public static let shared = DeviceDirectory(defaults: .standard)

    public static let storageKey = "pairedDevices"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    /// Les appareils, du plus récemment vu au plus ancien.
    public func all() -> [PairedDevice] {
        load().values.sorted { $0.lastSeen > $1.lastSeen }
    }

    public func device(_ deviceID: String) -> PairedDevice? {
        load()[deviceID]
    }

    public func contains(_ deviceID: String) -> Bool {
        load()[deviceID] != nil
    }

    /// Ajoute l'appareil, ou met à jour ce qu'on sait de lui sans écraser le reste.
    public func record(deviceID: String, name: String, transport: TransportKind?) {
        var entries = load()
        var entry = entries[deviceID] ?? PairedDevice(deviceID: deviceID, name: name)
        entry.name = name
        if let transport { entry.lastTransport = transport }
        entry.lastSeen = Date()
        entries[deviceID] = entry
        save(entries)
    }

    public func setResumesSharing(_ resumes: Bool, for deviceID: String) {
        var entries = load()
        guard var entry = entries[deviceID] else { return }
        entry.resumesSharing = resumes
        entries[deviceID] = entry
        save(entries)
    }

    /// Identifiants dont le partage doit reprendre à la réapparition.
    public func resuming() -> Set<String> {
        Set(load().values.filter(\.resumesSharing).map(\.deviceID))
    }

    public func remove(_ deviceID: String) {
        var entries = load()
        entries.removeValue(forKey: deviceID)
        save(entries)
    }

    public func removeAll() {
        defaults.removeObject(forKey: Self.storageKey)
    }

    private func load() -> [String: PairedDevice] {
        guard let data = defaults.data(forKey: Self.storageKey),
            let entries = try? JSONDecoder().decode([String: PairedDevice].self, from: data)
        else { return [:] }
        return entries
    }

    private func save(_ entries: [String: PairedDevice]) {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}
