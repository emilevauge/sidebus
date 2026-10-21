import Foundation
import Observation
import SidebusCore
import os

/// What a device row shows, in the menu as in the settings.
///
/// The row carries the session rather than a copy of its state: the session is what changes
/// while streaming, and SwiftUI only tracks what it reads. A frozen copy would show the
/// bitrate of the moment the list was built.
@MainActor
struct DeviceEntry: Identifiable {
    /// Persistent identifier of the tablet, or discovery key while it stays unknown.
    let id: String
    let name: String
    let isPaired: Bool

    /// Transport the device is visible on right now, `nil` when it is offline.
    let transport: TransportKind?

    /// Session in progress for this device, pairing or sharing.
    let session: DeviceSession?

    /// Text shown for a paired device that is offline.
    let offlineDetail: String?

    /// True for a hand typed address: it gets forgotten, not unpaired.
    let isManual: Bool

    var isOnline: Bool { transport != nil }

    /// True as soon as sharing is asked for, even before the first frame.
    var isSharing: Bool { session?.mode == .sharing }

    /// Connecting, pairing or preparing the stream: something is under way, but nothing
    /// shows on the tablet yet.
    var isBusy: Bool {
        guard let session else { return false }
        return !session.isStreaming
    }

    var detail: String? { session?.detail ?? offlineDetail }

    /// What a click on the row does.
    enum Action: Equatable {
        case pair
        case startSharing
        case stopSharing
        case none
    }

    var action: Action {
        guard isOnline else { return .none }
        // A session in progress stops, whether it is pairing or preparing the stream.
        // Without that, a tablet that does not answer blocks the row.
        if session != nil { return .stopSharing }
        return isPaired ? .startSharing : .pair
    }

    /// Symbol of the row. It carries the state on its own, and that is what makes the menu
    /// readable at a glance.
    var symbol: String {
        guard isOnline else { return "ipad.slash" }
        if isBusy { return "hourglass" }
        if session != nil { return "stop.circle.fill" }
        return isPaired ? "play.rectangle.on.rectangle" : "link.badge.plus"
    }

    var transportLabel: String {
        switch transport {
        case .usb: return "USB"
        case .wifi: return "Wi-Fi"
        case nil: return "offline"
        }
    }
}

/// Tablet discovery, and running the shares.
///
/// On USB: follows the devices adb sees, sets up the port tunnel, opens the link.
/// On Wi-Fi: follows the mDNS advertisements and connects to the published endpoint.
///
/// Nothing streams without a gesture: discover, pair, then start sharing device by device.
/// One exception, deliberate: a device that was being shared to resumes on its own when it
/// reappears, otherwise plugging a cable back in would mean reopening the menu every time.
@MainActor
@Observable
final class DeviceManager {

    /// Resolution setting: 1.0, 0.75 or 0.5.
    static let resolutionScaleKey = "resolutionScale"

    private(set) var status = "idle"
    private(set) var entries: [DeviceEntry] = []

    /// Tablets added by hand through their IP address. The fallback that saves the day on
    /// networks blocking multicast.
    private(set) var manualPeers: [Peer] = []

    /// Last pairing refusal to display, whichever session produced it.
    private(set) var lastRefusal: String?

    @ObservationIgnored
    private let watcher = AdbWatcher()
    @ObservationIgnored
    private let browser = BonjourBrowser()
    @ObservationIgnored
    private var registry = PeerRegistry()
    @ObservationIgnored
    private let directory = DeviceDirectory.shared
    @ObservationIgnored
    private var sessions: [String: DeviceSession] = [:]
    @ObservationIgnored
    private var watchTask: Task<Void, Never>?
    @ObservationIgnored
    private var browseTask: Task<Void, Never>?

    /// Devices the user wants shared. Persisted in the directory, and that is what drives
    /// the automatic resume.
    @ObservationIgnored
    private var sharingIntent: Set<String> = []

    @ObservationIgnored
    private let log = Logger(subsystem: "app.sidebus", category: "devices")

    /// The Mac's identity, stable from one launch to the next.
    @ObservationIgnored
    private lazy var macUUID: UUID = {
        let key = "macUUID"
        if let stored = UserDefaults.standard.string(forKey: key), let uuid = UUID(uuidString: stored) {
            return uuid
        }
        let uuid = UUID()
        UserDefaults.standard.set(uuid.uuidString, forKey: key)
        return uuid
    }()

    private var macName: String { Host.current().localizedName ?? "Mac" }

    init() {
        sharingIntent = directory.resuming()
        start()
    }

    // MARK: - Settings

    func setResolutionScale(_ scale: Double) {
        UserDefaults.standard.set(scale, forKey: Self.resolutionScaleKey)
    }

    var resolutionScale: Double {
        UserDefaults.standard.object(forKey: Self.resolutionScaleKey) as? Double ?? 1.0
    }

    /// Paired devices, offline ones included, for the settings window.
    ///
    /// Stored rather than computed from the directory: a computed property reading the
    /// preferences does not announce itself to SwiftUI, and the window kept showing a
    /// device that had just been unpaired.
    private(set) var pairedDevices: [PairedDevice] = []

    /// Number of shares in progress. Stored rather than computed: `sessions` is not
    /// observed, and the menu bar has to change its icon when this moves.
    private(set) var sharingCount = 0

    /// One line summary for the top of the menu.
    var summary: String {
        if sharingCount > 0 {
            return sharingCount == 1
                ? "1 screen shared"
                : "\(sharingCount) screens shared"
        }
        let online = entries.count(where: \.isOnline)
        if online == 0 { return status }
        return online == 1 ? "1 device visible" : "\(online) devices visible"
    }

    // MARK: - Discovery

    func start() {
        registry.serialToDevice = Self.loadKnownSerials()
        status = "waiting for a tablet"

        // Development hook: exercises the Wi-Fi path on a machine where the tablet only
        // shows up over USB.
        let usbDisabled = ProcessInfo.processInfo.environment["SIDEBUS_DISABLE_USB"] == "1"

        if usbDisabled {
            log.info("USB discovery disabled (SIDEBUS_DISABLE_USB)")
            status = "USB disabled, Wi-Fi only"
        } else if AdbWatcher.locateAdb() == nil {
            // Without adb, Wi-Fi still works: say so and carry on, rather than failing in
            // silence.
            log.error("adb not found, USB discovery unavailable")
            status = "adb not found, Wi-Fi only"
        } else if watchTask == nil {
            watchTask = Task { [watcher] in
                let peers = await watcher.start()
                for await list in peers {
                    self.handle(usb: list)
                }
                self.handle(usb: [])
                self.watchTask = nil
            }
        }

        // Development hook: prefills a manual address, as typing one in the settings would.
        if let seed = ProcessInfo.processInfo.environment["SIDEBUS_MANUAL_PEER"], !seed.isEmpty {
            addManualPeer(address: seed)
        }

        if browseTask == nil {
            browseTask = Task { [browser] in
                let peers = await browser.start()
                for await list in peers {
                    self.handle(wifi: list)
                }
                self.handle(wifi: [])
                self.browseTask = nil
            }
        }
        refreshEntries()
    }

    func stop() {
        watchTask?.cancel()
        watchTask = nil
        browseTask?.cancel()
        browseTask = nil
        let running = Array(sessions.values)
        sessions.removeAll()
        Task { [watcher, browser] in
            for session in running {
                await session.stop(bye: .normal, status: "Sidebus shutting down")
            }
            await watcher.stop()
            await browser.stop()
        }
    }

    /// Adds a tablet by its address, when the mDNS advertisement does not get through.
    func addManualPeer(address: String) {
        let trimmed = address.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }

        let parts = trimmed.split(separator: ":")
        let host = String(parts[0])
        let port = parts.count > 1 ? UInt16(parts[1]) ?? Sidebus.port : Sidebus.port

        let peer = Peer(id: "manuel-\(host):\(port)", name: host, kind: .wifi, host: host, port: port)
        manualPeers.removeAll { $0.id == peer.id }
        manualPeers.append(peer)
        log.info("tablet added by hand: \(host, privacy: .public):\(port)")
        reconcile()
    }

    func removeManualPeer(id: String) {
        log.info("typed address forgotten: \(id, privacy: .public)")
        manualPeers.removeAll { $0.id == id }
        reconcile()
    }

    /// Identifier of the hand typed peer hiding behind a device key.
    func manualPeerID(forKey key: String) -> String? {
        manualPeers.first { self.key(for: $0) == key }?.id
    }

    func removeManualPeers() {
        manualPeers.removeAll()
        reconcile()
    }

    private func handle(usb: [Peer]? = nil, wifi: [Peer]? = nil) {
        if let usb { registry.usbPeers = usb }
        if let wifi {
            if wifi.map(\.id) != registry.wifiPeers.map(\.id) {
                log.info("annonces Wi-Fi : \(wifi.map(\.name).joined(separator: ", "), privacy: .public)")
            }
            registry.wifiPeers = wifi
        }
        reconcile()
    }

    // MARK: - Device identity

    private static let knownSerialsKey = "serialToDevice"

    private static func loadKnownSerials() -> [String: UUID] {
        let stored = UserDefaults.standard.dictionary(forKey: knownSerialsKey) as? [String: String] ?? [:]
        return stored.compactMapValues(UUID.init(uuidString:))
    }

    private func rememberSerial(_ serial: String, deviceID: UUID) {
        guard registry.serialToDevice[serial] != deviceID else { return }
        registry.serialToDevice[serial] = deviceID
        let stored = registry.serialToDevice.mapValues(\.uuidString)
        UserDefaults.standard.set(stored, forKey: Self.knownSerialsKey)
        log.info("serial \(serial, privacy: .public) tied to the device")
    }

    /// Stable key of a peer: its persistent identifier as soon as we know it, otherwise a
    /// key derived from the discovery channel. A tablet seen on both USB and Wi-Fi has one
    /// key, and that is what makes it appear once in the list.
    private func key(for peer: Peer) -> String {
        if let deviceID = peer.deviceID { return deviceID.uuidString }
        if peer.kind == .usb, let learned = registry.serialToDevice[peer.id] {
            return learned.uuidString
        }
        return "\(peer.kind.rawValue)-\(peer.id)"
    }

    /// Every visible peer, grouped by device, USB first since it always wins.
    private func visiblePeers() -> [String: [Peer]] {
        var grouped: [String: [Peer]] = [:]
        for peer in registry.resolved() + manualPeers {
            grouped[key(for: peer), default: []].append(peer)
        }
        for key in grouped.keys {
            grouped[key]?.sort { left, _ in left.kind == .usb }
        }
        return grouped
    }

    /// Best peer for a device: USB when present, Wi-Fi otherwise.
    private func bestPeer(for key: String) -> Peer? {
        visiblePeers()[key]?.first
    }

    // MARK: - Menu actions

    func perform(_ entry: DeviceEntry) {
        switch entry.action {
        case .pair: pair(entry.id)
        case .startSharing: startSharing(entry.id)
        case .stopSharing: stopSharing(entry.id)
        case .none: break
        }
    }

    /// Opens a link long enough to pair, then hangs up. Sharing stays a separate gesture.
    func pair(_ key: String) {
        guard sessions[key] == nil, let peer = bestPeer(for: key) else { return }
        lastRefusal = nil
        log.info("pairing with \(peer.name, privacy: .public)")
        sessions[key] = makeSession(key: key, mode: .pairing, peer: peer)
        sessions[key]?.start()
        refreshEntries()
    }

    func startSharing(_ key: String) {
        guard directory.contains(key) else { return }
        sharingIntent.insert(key)
        directory.setResumesSharing(true, for: key)
        reconcile()
    }

    func stopSharing(_ key: String) {
        sharingIntent.remove(key)
        directory.setResumesSharing(false, for: key)
        guard let session = sessions.removeValue(forKey: key) else {
            refreshEntries()
            return
        }
        log.notice("sharing stopped for \(key, privacy: .public)")
        refreshEntries()
        Task {
            await session.stop(bye: .normal, status: "sharing stopped")
            self.refreshEntries()
        }
    }

    /// Forgets a device: keychain fingerprint, directory entry, session in progress.
    func unpair(_ key: String) {
        log.info("unpairing \(key, privacy: .public)")
        stopSharing(key)
        directory.remove(key)
        refreshEntries()
        Task {
            await Task.detached { PairingStore.shared.remove(deviceID: key) }.value
            self.refreshEntries()
        }
    }

    func unpairAll() {
        log.info("every device forgotten")
        for key in sharingIntent { stopSharing(key) }
        directory.removeAll()
        refreshEntries()
        Task {
            await Task.detached { PairingStore.shared.removeAll() }.value
            self.refreshEntries()
        }
    }

    // MARK: - Reconciliation

    /// Decides what to do with the current state: start a wanted share, follow a transport
    /// switch, or take note of a disappearance.
    private func reconcile() {
        let visible = visiblePeers()

        for key in sharingIntent where directory.contains(key) {
            guard let peer = visible[key]?.first else { continue }

            guard let session = sessions[key] else {
                log.notice("sharing to \(peer.name, privacy: .public) over \(peer.kind.rawValue, privacy: .public)")
                let session = makeSession(key: key, mode: .sharing, peer: peer)
                sessions[key] = session
                session.start()
                continue
            }

            // Clean switch to a better transport: BYE with the proper code, close, then
            // reconnect. No live socket migration, the gain is not worth the complexity,
            // and a 200 ms cut when the cable goes in passes unnoticed.
            if session.mode == .sharing, session.peer.kind == .wifi, peer.kind == .usb {
                log.notice("switching Wi-Fi to USB for \(peer.name, privacy: .public)")
                sessions.removeValue(forKey: key)
                Task {
                    await session.stop(bye: .transportSwitch, status: "transport switch")
                    self.reconcile()
                }
            }
        }

        refreshEntries()
    }

    private func makeSession(key: String, mode: DeviceSession.Mode, peer: Peer) -> DeviceSession {
        let session = DeviceSession(
            key: key,
            mode: mode,
            peer: peer,
            macName: macName,
            macUUID: macUUID,
            watcher: watcher,
            peerForKey: { [weak self] key in self?.bestPeer(for: key) },
            onIdentified: { [weak self] uuid, device, peer in
                self?.identified(uuid: uuid, device: device, peer: peer)
            },
            onFinished: { [weak self] finished in
                self?.finished(finished)
            }
        )
        session.systemStoppedCapture = { [weak self] stopped in
            guard let self else { return }
            log.notice("capture cut by macOS, sharing dropped for \(stopped.key, privacy: .public)")
            self.stopSharing(stopped.key)
        }
        return session
    }

    /// DEVICE_INFO received: the tablet's persistent identifier is finally known.
    private func identified(
        uuid: UUID,
        device: PeerSession.DeviceDescription,
        peer: Peer
    ) {
        if peer.kind == .usb {
            rememberSerial(peer.id, deviceID: uuid)
        }
        directory.record(deviceID: uuid.uuidString, name: device.name, transport: peer.kind)

        // The session was running under a provisional key taken from the adb serial. It now
        // takes the device's own, otherwise the list would show two rows for one tablet.
        let identifier = uuid.uuidString
        if let (oldKey, session) = sessions.first(
            where: { $0.key != identifier && $0.value.peer.id == peer.id }
        ) {
            sessions.removeValue(forKey: oldKey)
            session.adopt(key: identifier)
            sessions[identifier] = session
            if sharingIntent.remove(oldKey) != nil {
                sharingIntent.insert(identifier)
                directory.setResumesSharing(true, for: identifier)
            }
        }
        refreshEntries()
    }

    private func finished(_ session: DeviceSession) {
        if sessions[session.key] === session {
            sessions.removeValue(forKey: session.key)
        }
        if let refusal = session.pairing.lastRefusal {
            lastRefusal = refusal
            // A refused pairing must not leave the sharing intent behind.
            sharingIntent.remove(session.key)
        }
        refreshEntries()
    }

    // MARK: - Displayed list

    /// Rebuilds the rows from what is visible and what is paired. Online devices first, then
    /// the paired ones that are offline.
    private func refreshEntries() {
        let visible = visiblePeers()
        let paired = Dictionary(uniqueKeysWithValues: directory.all().map { ($0.deviceID, $0) })
        let manualKeys = Set(manualPeers.map(key(for:)))

        var rows: [DeviceEntry] = []

        for (key, peers) in visible {
            let peer = peers[0]
            let session = sessions[key]
            let record = paired[key]
            rows.append(
                DeviceEntry(
                    id: key,
                    name: record?.name ?? session?.deviceName ?? peer.name,
                    isPaired: record != nil,
                    transport: peer.kind,
                    session: session,
                    offlineDetail: nil,
                    isManual: manualKeys.contains(key)
                )
            )
        }

        // A tablet whose identity was reset pairs again under a new identifier and leaves
        // its old pairings behind, offline for good: show one row per name, the most
        // recently seen, and none when that name is online. The settings list them all.
        let onlineNames = Set(rows.map(\.name))
        var offlineNames = Set<String>()
        let offline = paired.values
            .filter { visible[$0.deviceID] == nil }
            .sorted { $0.lastSeen > $1.lastSeen }
            .filter { !onlineNames.contains($0.name) && offlineNames.insert($0.name).inserted }

        for device in offline {
            rows.append(
                DeviceEntry(
                    id: device.deviceID,
                    name: device.name,
                    isPaired: true,
                    transport: nil,
                    session: nil,
                    offlineDetail: "seen over \(Self.describe(device.lastTransport)), \(Self.ago(device.lastSeen))",
                    isManual: false
                )
            )
        }

        sharingCount = sessions.values.count { $0.mode == .sharing }
        pairedDevices = directory.all()
        entries = rows.sorted {
            if $0.isOnline != $1.isOnline { return $0.isOnline }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }

        if entries.isEmpty { status = "waiting for a tablet" }
    }

    private static func describe(_ transport: TransportKind?) -> String {
        switch transport {
        case .usb: return "USB"
        case .wifi: return "Wi-Fi"
        case nil: return "unknown transport"
        }
    }

    private static func ago(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
