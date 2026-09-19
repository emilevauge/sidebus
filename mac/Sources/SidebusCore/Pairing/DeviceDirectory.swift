import Foundation

/// A paired device, as the menu and the settings show it.
///
/// The certificate fingerprint lives in `PairingStore`, not here: the two are different in
/// nature. The fingerprint is integrity data, and it decides whether a link is accepted or
/// refused. What follows is display and convenience, and losing it costs nothing.
public struct PairedDevice: Codable, Sendable, Hashable, Identifiable {
    public var id: String { deviceID }

    /// Persistent identifier of the tablet, in text form. It is the key to everything.
    public let deviceID: String
    public var name: String

    /// Last transport it was seen on, so it can be shown while offline.
    public var lastTransport: TransportKind?
    public var lastSeen: Date

    /// True when sharing to this device should resume on its own once it reappears. Set
    /// when sharing starts, cleared when it stops.
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

/// The paired devices, keyed by identifier.
///
/// Stored in the preferences, as JSON. Nothing here is secret, and losing the file does not
/// break pairing: the fingerprints stay in the keychain, only the names and the automatic
/// resume disappear.
public struct DeviceDirectory: @unchecked Sendable {
    public static let shared = DeviceDirectory(defaults: .standard)

    public static let storageKey = "pairedDevices"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    /// The devices, most recently seen first.
    public func all() -> [PairedDevice] {
        load().values.sorted { $0.lastSeen > $1.lastSeen }
    }

    public func device(_ deviceID: String) -> PairedDevice? {
        load()[deviceID]
    }

    public func contains(_ deviceID: String) -> Bool {
        load()[deviceID] != nil
    }

    /// Adds the device, or updates what is known about it without erasing the rest.
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

    /// Identifiers whose sharing should resume when they reappear.
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
