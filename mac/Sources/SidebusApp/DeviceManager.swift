import Foundation
import Observation
import SidebusCore
import os

/// Ce qu'une ligne d'appareil affiche, dans le menu comme dans les réglages.
///
/// La ligne porte la session plutôt qu'une copie de son état : c'est elle qui change
/// pendant la diffusion, et SwiftUI ne suit ce qu'il lit. Une copie figée montrerait le
/// débit du moment où la liste a été construite.
@MainActor
struct DeviceEntry: Identifiable {
    /// Identifiant persistant de la tablette, ou clé de découverte tant qu'il est inconnu.
    let id: String
    let name: String
    let isPaired: Bool

    /// Transport par lequel l'appareil est visible en ce moment, `nil` s'il est hors ligne.
    let transport: TransportKind?

    /// Session en cours pour cet appareil, appairage ou partage.
    let session: DeviceSession?

    /// Texte affiché pour un appareil appairé mais hors ligne.
    let offlineDetail: String?

    var isOnline: Bool { transport != nil }

    /// Vrai dès qu'un partage est demandé pour cet appareil, même avant la première frame.
    var isSharing: Bool { session?.mode == .sharing }

    /// Connexion, appairage ou préparation du flux : quelque chose est en cours, mais rien
    /// ne s'affiche encore sur la tablette.
    var isBusy: Bool {
        guard let session else { return false }
        return !session.isStreaming
    }

    var detail: String? { session?.detail ?? offlineDetail }

    /// Ce que fait un clic sur la ligne.
    enum Action: Equatable {
        case pair
        case startSharing
        case stopSharing
        case none
    }

    var action: Action {
        guard isOnline else { return .none }
        // Une session en cours s'interrompt, qu'elle soit en train d'appairer ou de
        // préparer le flux : sans ça une tablette qui ne répond pas bloque la ligne.
        if session != nil { return .stopSharing }
        return isPaired ? .startSharing : .pair
    }

    /// Symbole de la ligne. Il porte l'état à lui seul : c'est ce qui rend le menu lisible
    /// d'un coup d'œil.
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
        case nil: return "hors ligne"
        }
    }
}

/// Découverte des tablettes et conduite des partages.
///
/// En USB : suit les appareils vus par adb, pose le tunnel de port, ouvre le lien.
/// En Wi-Fi : suit les annonces mDNS et se connecte à l'endpoint publié.
///
/// Rien n'est diffusé sans un geste : on découvre, on appaire, puis on lance le partage
/// appareil par appareil. Seule exception, voulue : un appareil dont le partage était actif
/// reprend tout seul quand il réapparaît, sans quoi rebrancher un câble demanderait de
/// rouvrir le menu à chaque fois.
@MainActor
@Observable
final class DeviceManager {

    /// Réglage de résolution : 1.0, 0.75 ou 0.5.
    static let resolutionScaleKey = "resolutionScale"

    private(set) var status = "inactif"
    private(set) var entries: [DeviceEntry] = []

    /// Tablettes ajoutées à la main par adresse IP. Le repli qui sauve l'expérience sur
    /// les réseaux qui bloquent le multicast.
    private(set) var manualPeers: [Peer] = []

    /// Dernier refus d'appairage à afficher, quelle que soit la session qui l'a produit.
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

    /// Appareils dont l'utilisateur veut le partage. Persisté dans l'annuaire, c'est lui
    /// qui pilote la reprise automatique.
    @ObservationIgnored
    private var sharingIntent: Set<String> = []

    @ObservationIgnored
    private let log = Logger(subsystem: "app.sidebus", category: "devices")

    /// Identité du Mac, stable d'un lancement à l'autre.
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

    // MARK: - Réglages

    func setResolutionScale(_ scale: Double) {
        UserDefaults.standard.set(scale, forKey: Self.resolutionScaleKey)
    }

    var resolutionScale: Double {
        UserDefaults.standard.object(forKey: Self.resolutionScaleKey) as? Double ?? 1.0
    }

    /// Appareils appairés, y compris hors ligne, pour la fenêtre de réglages.
    var pairedDevices: [PairedDevice] { directory.all() }

    /// Nombre de partages en cours. Stocké plutôt que calculé : `sessions` n'est pas
    /// observé, et la barre de menus doit changer d'icône quand il bouge.
    private(set) var sharingCount = 0

    /// Résumé d'une ligne pour le haut du menu.
    var summary: String {
        if sharingCount > 0 {
            return sharingCount == 1
                ? "1 écran partagé"
                : "\(sharingCount) écrans partagés"
        }
        let online = entries.count(where: \.isOnline)
        if online == 0 { return status }
        return online == 1 ? "1 appareil visible" : "\(online) appareils visibles"
    }

    // MARK: - Découverte

    func start() {
        registry.serialToDevice = Self.loadKnownSerials()
        status = "en attente d'une tablette"

        // Crochet de développement : permet d'exercer la branche Wi-Fi sur une machine où
        // la tablette n'est visible qu'en USB.
        let usbDisabled = ProcessInfo.processInfo.environment["SIDEBUS_DISABLE_USB"] == "1"

        if usbDisabled {
            log.info("découverte USB désactivée (SIDEBUS_DISABLE_USB)")
            status = "USB désactivé, Wi-Fi seulement"
        } else if AdbWatcher.locateAdb() == nil {
            // Sans adb, le Wi-Fi reste disponible : on le dit et on continue, plutôt que
            // d'échouer en silence.
            log.error("adb introuvable, découverte USB indisponible")
            status = "adb introuvable, Wi-Fi seulement"
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

        // Crochet de développement : préremplit une adresse manuelle, comme le ferait la
        // saisie du menu.
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
                await session.stop(bye: .normal, status: "arrêt de Sidebus")
            }
            await watcher.stop()
            await browser.stop()
        }
    }

    /// Ajoute une tablette par son adresse, quand l'annonce mDNS ne passe pas.
    func addManualPeer(address: String) {
        let trimmed = address.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }

        let parts = trimmed.split(separator: ":")
        let host = String(parts[0])
        let port = parts.count > 1 ? UInt16(parts[1]) ?? Sidebus.port : Sidebus.port

        let peer = Peer(id: "manuel-\(host):\(port)", name: host, kind: .wifi, host: host, port: port)
        manualPeers.removeAll { $0.id == peer.id }
        manualPeers.append(peer)
        log.info("tablette ajoutée à la main : \(host, privacy: .public):\(port)")
        reconcile()
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

    // MARK: - Identité des appareils

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
        log.info("série \(serial, privacy: .public) associée à l'appareil")
    }

    /// Clé stable d'un pair : son identifiant persistant dès qu'on le connaît, sinon une
    /// clé dérivée du moyen de découverte. Une tablette vue en USB et en Wi-Fi n'a qu'une
    /// clé, c'est ce qui la fait apparaître une seule fois dans la liste.
    private func key(for peer: Peer) -> String {
        if let deviceID = peer.deviceID { return deviceID.uuidString }
        if peer.kind == .usb, let learned = registry.serialToDevice[peer.id] {
            return learned.uuidString
        }
        return "\(peer.kind.rawValue)-\(peer.id)"
    }

    /// Tous les pairs visibles, groupés par appareil, USB d'abord puisqu'il gagne toujours.
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

    /// Meilleur pair pour un appareil : l'USB s'il est là, sinon le Wi-Fi.
    private func bestPeer(for key: String) -> Peer? {
        visiblePeers()[key]?.first
    }

    // MARK: - Actions du menu

    func perform(_ entry: DeviceEntry) {
        switch entry.action {
        case .pair: pair(entry.id)
        case .startSharing: startSharing(entry.id)
        case .stopSharing: stopSharing(entry.id)
        case .none: break
        }
    }

    /// Ouvre un lien le temps d'appairer, puis raccroche. Le partage reste un geste à part.
    func pair(_ key: String) {
        guard sessions[key] == nil, let peer = bestPeer(for: key) else { return }
        lastRefusal = nil
        log.info("appairage de \(peer.name, privacy: .public)")
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
        log.info("partage arrêté pour \(key, privacy: .public)")
        refreshEntries()
        Task {
            await session.stop(bye: .normal, status: "partage arrêté")
            self.refreshEntries()
        }
    }

    /// Oublie un appareil : empreinte du trousseau, entrée d'annuaire, session en cours.
    func unpair(_ key: String) {
        log.info("désappairage de \(key, privacy: .public)")
        stopSharing(key)
        directory.remove(key)
        Task {
            await Task.detached { PairingStore.shared.remove(deviceID: key) }.value
            self.refreshEntries()
        }
    }

    func unpairAll() {
        log.info("tous les appareils oubliés")
        for key in sharingIntent { stopSharing(key) }
        directory.removeAll()
        Task {
            await Task.detached { PairingStore.shared.removeAll() }.value
            self.refreshEntries()
        }
    }

    // MARK: - Réconciliation

    /// Décide quoi faire de l'état courant : lancer un partage voulu, suivre une bascule de
    /// transport, ou constater une disparition.
    private func reconcile() {
        let visible = visiblePeers()

        for key in sharingIntent where directory.contains(key) {
            guard let peer = visible[key]?.first else { continue }

            guard let session = sessions[key] else {
                log.info("partage de \(peer.name, privacy: .public) en \(peer.kind.rawValue, privacy: .public)")
                let session = makeSession(key: key, mode: .sharing, peer: peer)
                sessions[key] = session
                session.start()
                continue
            }

            // Bascule propre vers un meilleur transport : BYE avec le code prévu, fermeture,
            // puis reconnexion. Pas de migration de socket à chaud, le gain ne vaut pas la
            // complexité, et une coupure de 200 ms au branchement du câble passe inaperçue.
            if session.mode == .sharing, session.peer.kind == .wifi, peer.kind == .usb {
                log.info("bascule Wi-Fi vers USB pour \(peer.name, privacy: .public)")
                sessions.removeValue(forKey: key)
                Task {
                    await session.stop(bye: .transportSwitch, status: "bascule de transport")
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
            log.info("capture coupée par macOS, partage retiré pour \(stopped.key, privacy: .public)")
            self.stopSharing(stopped.key)
        }
        return session
    }

    /// DEVICE_INFO reçu : on connaît enfin l'identifiant persistant de la tablette.
    private func identified(
        uuid: UUID,
        device: PeerSession.DeviceDescription,
        peer: Peer
    ) {
        if peer.kind == .usb {
            rememberSerial(peer.id, deviceID: uuid)
        }
        directory.record(deviceID: uuid.uuidString, name: device.name, transport: peer.kind)

        // La session tournait sous une clé provisoire, tirée du numéro de série adb :
        // elle prend maintenant celle de l'appareil, sinon la liste montrerait deux lignes
        // pour la même tablette.
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
            // Un appairage refusé ne doit pas laisser l'intention de partage derrière lui.
            sharingIntent.remove(session.key)
        }
        refreshEntries()
    }

    // MARK: - Liste affichée

    /// Reconstruit les lignes à partir de ce qui est visible et de ce qui est appairé.
    /// Les appareils en ligne d'abord, les appairés hors ligne ensuite.
    private func refreshEntries() {
        let visible = visiblePeers()
        let paired = Dictionary(uniqueKeysWithValues: directory.all().map { ($0.deviceID, $0) })

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
                    offlineDetail: nil
                )
            )
        }

        for device in paired.values where visible[device.deviceID] == nil {
            rows.append(
                DeviceEntry(
                    id: device.deviceID,
                    name: device.name,
                    isPaired: true,
                    transport: nil,
                    session: nil,
                    offlineDetail: "vu en \(Self.describe(device.lastTransport)), \(Self.ago(device.lastSeen))"
                )
            )
        }

        sharingCount = sessions.values.count { $0.mode == .sharing }
        entries = rows.sorted {
            if $0.isOnline != $1.isOnline { return $0.isOnline }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }

        if entries.isEmpty { status = "en attente d'une tablette" }
    }

    private static func describe(_ transport: TransportKind?) -> String {
        switch transport {
        case .usb: return "USB"
        case .wifi: return "Wi-Fi"
        case nil: return "transport inconnu"
        }
    }

    private static func ago(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "fr_FR")
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
