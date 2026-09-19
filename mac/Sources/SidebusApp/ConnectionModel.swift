import CoreGraphics
import CoreMedia
import Foundation
import Observation
import SidebusCore
import os

/// Conduit la découverte et la connexion, sur les deux transports.
///
/// En USB : suit les appareils vus par adb, pose le tunnel de port, ouvre le lien.
/// En Wi-Fi : suit les annonces mDNS et se connecte à l'endpoint publié.
/// Aucun code au delà de cette classe ne sait par où passe le lien.
@MainActor
@Observable
final class ConnectionModel {
    private(set) var status = "inactif"
    private(set) var deviceName: String?
    private(set) var deviceResolution: String?
    private(set) var roundTripMilliseconds: Double?
    private(set) var isConnected = false

    @ObservationIgnored
    private let watcher = AdbWatcher()
    @ObservationIgnored
    private let browser = BonjourBrowser()
    @ObservationIgnored
    private var registry = PeerRegistry()
    @ObservationIgnored
    private var browseTask: Task<Void, Never>?
    @ObservationIgnored
    private var session: PeerSession?

    /// Tablettes ajoutées à la main par adresse IP. Le repli qui sauve l'expérience sur
    /// les réseaux qui bloquent le multicast.
    private(set) var manualPeers: [Peer] = []

    /// Tablette à laquelle on est connecté ou en train de se connecter.
    private(set) var currentPeer: Peer?
    @ObservationIgnored
    let pairing = PairingValidator()
    @ObservationIgnored
    private var watchTask: Task<Void, Never>?
    @ObservationIgnored
    private var sessionTask: Task<Void, Never>?
    @ObservationIgnored
    private var failureCount = 0
    @ObservationIgnored
    private var capture: CaptureSession?
    @ObservationIgnored
    private var streamTask: Task<Void, Never>?
    @ObservationIgnored
    private var injector: EventInjector?

    /// Vrai quand l'autorisation Accessibilité manque : les touchers sont alors reçus mais
    /// ne produisent rien.
    private(set) var needsAccessibilityPermission = false

    private(set) var streamDescription: String?

    /// Vrai quand l'écran virtuel a échoué et qu'on recopie un écran existant.
    private(set) var usesFallbackDisplay = false

    /// Réglage de résolution : 1.0, 0.75 ou 0.5.
    static let resolutionScaleKey = "resolutionScale"

    @ObservationIgnored
    private var bitrateController = BitrateController(profile: .usb)
    @ObservationIgnored
    private var currentFrameRate = 60

    private(set) var currentBitrate: Int?
    private(set) var dropRatePercent: Int?

    func setResolutionScale(_ scale: Double) {
        UserDefaults.standard.set(scale, forKey: Self.resolutionScaleKey)
    }

    var resolutionScale: Double {
        UserDefaults.standard.object(forKey: Self.resolutionScaleKey) as? Double ?? 1.0
    }
    @ObservationIgnored
    private let log = Logger(subsystem: "app.sidebus", category: "transport")

    /// Identité du Mac, stable d'un lancement à l'autre. Elle partira dans HELLO et
    /// servira d'ancre à l'appairage en phase 6.
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

    init() {
        start()
    }

    private var macName: String {
        Host.current().localizedName ?? "Mac"
    }

    var menuLabel: String {
        if let deviceName, isConnected {
            let transport = currentPeer?.kind == .usb ? "USB" : "Wi-Fi"
            var label = "\(transport) : \(deviceName)"
            if let deviceResolution { label += ", \(deviceResolution)" }
            if let roundTripMilliseconds {
                label += String(format: ", %.1f ms", roundTripMilliseconds)
            }
            if let streamDescription {
                label += "\n\(streamDescription)"
            }
            if let currentBitrate {
                label += String(format: "\n%.1f Mbit/s", Double(currentBitrate) / 1_000_000)
                if let dropRatePercent, dropRatePercent > 0 {
                    label += ", \(dropRatePercent) %% droppées"
                }
            }
            if usesFallbackDisplay {
                label += "\nécran virtuel indisponible, recopie d'un écran existant"
            }
            if needsAccessibilityPermission {
                label += "\nAccessibilité refusée, le tactile est ignoré"
            }
            return label
        }

        let visible = registry.resolved().count + manualPeers.count
        if visible > 1 {
            return "\(status) (\(visible) tablettes visibles)"
        }
        return status
    }

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
    }

    func stop() {
        watchTask?.cancel()
        watchTask = nil
        browseTask?.cancel()
        browseTask = nil
        endSession(status: "inactif")
        Task { [watcher, browser] in
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

    // MARK: - Correspondances apprises

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

    /// Nouvelle liste vue par un des deux moyens de découverte.
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

    /// Décide quoi faire de l'état courant : se connecter, basculer, ou constater une
    /// disparition.
    private func reconcile() {
        let visible = registry.resolved() + manualPeers
        let preferred = registry.preferred() ?? manualPeers.first

        // La tablette courante n'est plus visible : câble débranché, app fermée, ou
        // sortie du réseau.
        if let current = currentPeer, !visible.contains(where: { $0.id == current.id }) {
            log.info("tablette \(current.id, privacy: .public) disparue")
            endSession(status: "tablette disparue")
        }

        guard let preferred else {
            if currentPeer == nil { status = "en attente d'une tablette" }
            return
        }

        if currentPeer == nil {
            currentPeer = preferred
            status = "connexion à \(preferred.name)"
            sessionTask = Task { await self.connect(to: preferred) }
            return
        }

        if registry.shouldSwitch(from: currentPeer, to: preferred) {
            switchTransport(to: preferred)
        }
    }

    /// Bascule propre vers un meilleur transport : BYE avec le code prévu, fermeture,
    /// puis reconnexion. Pas de migration de socket à chaud, le gain ne vaut pas la
    /// complexité, et une coupure de 200 ms au branchement du câble passe inaperçue.
    private func switchTransport(to peer: Peer) {
        log.info(
            """
            bascule \(self.currentPeer?.kind.rawValue ?? "?", privacy: .public) vers \
            \(peer.kind.rawValue, privacy: .public)
            """
        )
        status = "bascule vers \(peer.kind == .usb ? "l'USB" : "le Wi-Fi")"

        let previous = session
        sessionTask?.cancel()
        sessionTask = nil
        session = nil
        isConnected = false
        roundTripMilliseconds = nil

        // `currentPeer` est réaffecté tout de suite : le laisser à nil, même le temps
        // d'un aller retour asynchrone, laisse une fenêtre où une nouvelle découverte
        // lance une deuxième connexion par dessus la première.
        currentPeer = peer

        sessionTask = Task {
            if let previous {
                try? await previous.send(.bye(reason: .transportSwitch))
                await previous.stop(reason: "bascule de transport")
            }
            await self.stopStreaming()
            await self.connect(to: peer)
        }
    }

    /// Ferme la session courante sans toucher à la découverte.
    private func endSession(status newStatus: String, notify: Bool = true) {
        sessionTask?.cancel()
        sessionTask = nil
        session = nil
        currentPeer = nil
        isConnected = false
        deviceName = nil
        roundTripMilliseconds = nil
        if notify { status = newStatus }
        Task { await self.stopStreaming() }
    }


    private func connect(to peer: Peer, mayLaunchApp: Bool = true) async {
        var sawDeviceInfo = false
        log.info("connexion à \(peer.name, privacy: .public) en \(peer.kind.rawValue, privacy: .public)")

        do {
            if peer.kind == .usb {
                try await watcher.forward(
                    serial: peer.id,
                    localPort: Sidebus.port,
                    devicePort: Sidebus.port
                )
                log.info("tunnel adb posé pour \(peer.id, privacy: .public)")
            }

            // La connexion TCP réussit toujours : adb accepte en local même si rien
            // n'écoute sur l'appareil. C'est l'absence de DEVICE_INFO qui dit que
            // l'application n'est pas lancée.
            // Le chiffrement reste actif en USB : un seul chemin de code à maintenir et à
            // tester, et le surcoût de TLS 1.3 est négligeable devant l'encodage vidéo.
            let transport = TransportClient(
                endpoint: peer.endpoint,
                kind: peer.kind,
                validator: pairing,
                expectedDeviceID: peer.deviceID?.uuidString
            )
            do {
                try await withTimeout(.seconds(8)) { try await transport.connect() }
            } catch is CancellationError {
                // Bascule de transport ou arrêt demandé : ce n'est pas un échec.
                await transport.close()
                return
            } catch {
                await transport.close()
                if case TransportError.timedOut = error, peer.kind == .wifi {
                    // Le réseau accepte l'annonce mais laisse tomber les paquets : c'est
                    // la signature de l'isolation des clients, qu'aucun code ne contourne.
                    status = """
                        \(peer.name) est annoncée mais ne répond pas. Le réseau isole \
                        probablement ses appareils entre eux : essayez l'USB, un autre \
                        réseau, ou le partage de connexion.
                        """
                    log.error("\(peer.name, privacy: .public) injoignable, isolation probable")
                }
                throw error
            }

            let session = PeerSession(transport: transport, macName: macName, macUUID: macUUID)
            self.session = session
            let events = try await session.start()

            for await event in events {
                switch event {
                case let .connected(device):
                    sawDeviceInfo = true
                    failureCount = 0
                    pairing.bind(deviceID: device.uuid)
                    if peer.kind == .usb {
                        rememberSerial(peer.id, deviceID: device.uuid)
                    }
                    isConnected = true
                    deviceName = device.name
                    deviceResolution = "\(device.width) × \(device.height)"
                    status = "connecté"
                    log.info(
                        """
                        connecté à \(device.name, privacy: .public), \
                        \(device.width)×\(device.height), \(device.density) dpi, \
                        codecs 0x\(String(device.codecs, radix: 16), privacy: .public)
                        """
                    )
                    await startStreaming(to: device, session: session)

                case let .roundTrip(milliseconds):
                    roundTripMilliseconds = milliseconds
                    log.debug("aller retour \(milliseconds, format: .fixed(precision: 2)) ms")

                case let .received(message):
                    if case let .stats(received, dropped, _) = message {
                        await applyStats(received: received, dropped: dropped)
                    } else if case .keyframeRequest = message {
                        // Le décodeur a perdu le fil : sans keyframe il reste noir
                        // jusqu'à la prochaine, soit cinq secondes.
                        log.debug("keyframe demandée par la tablette")
                        await capture?.requestKeyframe()
                    } else if case let .inputEvent(kind, x, y, button, _) = message {
                        log.debug(
                            """
                            INPUT_EVENT \(String(describing: kind), privacy: .public) \
                            x=\(x, format: .fixed(precision: 3)) \
                            y=\(y, format: .fixed(precision: 3))
                            """
                        )
                        await injector?.inject(kind: kind, x: x, y: y, button: button)
                    } else {
                        log.debug("message \(message.type) reçu")
                    }

                case let .closed(reason):
                    log.info("session fermée : \(reason, privacy: .public)")
                    await stopStreaming()
                    isConnected = false
                    roundTripMilliseconds = nil
                    status = "déconnecté (\(reason))"
                }
            }
        } catch is CancellationError {
            await stopStreaming()
            return
        } catch {
            log.error("connexion échouée : \(String(describing: error), privacy: .public)")
            status = "échec : \(error)"
            isConnected = false
        }

        await stopStreaming()

        session = nil
        sessionTask = nil
        currentPeer = nil

        let stillVisible = (registry.resolved() + manualPeers).contains { $0.id == peer.id }
        guard stillVisible else { return }

        // Jamais de DEVICE_INFO en USB : l'application n'est pas au premier plan sur la
        // tablette. On la lance et on réessaie une fois. En Wi-Fi il n'y a rien à lancer,
        // l'annonce ne vit que quand l'app tourne.
        if !sawDeviceInfo, mayLaunchApp, peer.kind == .usb {
            status = "lancement de l'app sur la tablette"
            log.info("aucun DEVICE_INFO, lancement de l'app sur \(peer.id, privacy: .public)")
            try? await watcher.launchApp(serial: peer.id)
            try? await Task.sleep(for: .seconds(1.5))
            guard currentPeer == nil else { return }
            currentPeer = peer
            sessionTask = Task { await self.connect(to: peer, mayLaunchApp: false) }
            return
        }

        // La tablette est toujours là : la session est tombée, pas le lien physique.
        // Reconnexion avec une pause qui s'allonge si ça échoue en boucle. Le vrai
        // backoff exponentiel arrive en phase 8.
        // Backoff exponentiel, plafonné : une tablette éteinte ne doit pas faire tourner
        // une boucle de reconnexion à vide. L'appairage, lui, n'est jamais redemandé.
        failureCount = sawDeviceInfo ? 0 : failureCount + 1
        let seconds = min(30, Int(pow(2.0, Double(min(failureCount, 5)))))
        log.debug("nouvelle tentative dans \(seconds) s")
        try? await Task.sleep(for: .seconds(seconds))

        guard (registry.resolved() + manualPeers).contains(where: { $0.id == peer.id }),
            currentPeer == nil
        else { return }

        currentPeer = peer
        status = "reconnexion à \(peer.name)"
        sessionTask = Task { await self.connect(to: peer) }
    }

    // MARK: - Diffusion

    /// Démarre la capture et pousse le flux sur le lien : DISPLAY_CONFIG, puis
    /// VIDEO_CONFIG à la première frame, puis les VIDEO_FRAME.
    private func startStreaming(to device: PeerSession.DeviceDescription, session: PeerSession) async {
        await stopStreaming()

        guard ScreenCapturer.isAuthorized() else {
            ScreenCapturer.requestAuthorization()
            status = "autorisation Enregistrement de l'écran manquante"
            return
        }

        let provider: any VirtualDisplayProvider
        let displayID: CGDirectDisplayID
        let displayName: String

        if let chosen = explicitlySelectedDisplay() {
            // L'utilisateur a désigné un écran : on le respecte.
            provider = ExistingDisplayProvider(targetID: chosen.id)
            displayID = chosen.id
            displayName = chosen.name
        } else {
            do {
                let virtual = CGVirtualDisplayProvider(
                    configuration: .init(
                        width: Int(device.width),
                        height: Int(device.height),
                        density: Int(device.density),
                        name: "Sidebus"
                    )
                )
                displayID = try await virtual.acquire()
                provider = virtual
                displayName = "écran virtuel"
            } catch {
                // L'API est privée : elle peut casser à n'importe quelle version de macOS.
                // On le dit, et on retombe sur un écran existant plutôt que d'échouer.
                log.error(
                    "écran virtuel indisponible (\(String(describing: error), privacy: .public)), repli sur un écran existant"
                )
                guard let fallback = firstExistingDisplay() else {
                    status = "connecté, aucun écran à capturer"
                    return
                }
                provider = ExistingDisplayProvider(targetID: fallback.id)
                displayID = fallback.id
                displayName = "\(fallback.name) (repli)"
                usesFallbackDisplay = true
            }
        }

        // Mêmes crochets de développement que pour la capture vers fichier.
        let environment = ProcessInfo.processInfo.environment
        // Défaut plus prudent en Wi-Fi : moins de pixels à transporter sur un lien qu'on
        // ne maîtrise pas.
        let defaultScale = currentPeer?.kind == .wifi ? 0.75 : 1.0
        let scale = environment["SIDEBUS_CAPTURE_SCALE"].flatMap(Double.init)
            ?? UserDefaults.standard.object(forKey: Self.resolutionScaleKey) as? Double
            ?? defaultScale
        let fps = environment["SIDEBUS_FPS"].flatMap(Int.init) ?? 60

        // HEVC dès que la tablette l'annonce : mesuré à 0,5 Mbit/s contre 1,4 en H.264
        // sur le même contenu, décodé en matériel sans une frame perdue.
        //
        // Attention aux décodeurs logiciels, celui de l'émulateur Android en particulier :
        // il rend des chromas cassées, blocs verts et magenta, là où H.264 passe. D'où
        // SIDEBUS_CODEC=h264, qui force le repli.
        let requested = environment["SIDEBUS_CODEC"]
        let codec: Codec = (requested != "h264" && device.supportsHEVC) ? .hevc : .h264
        let profile: BitrateController.Profile = currentPeer?.kind == .usb ? .usb : .wifi
        bitrateController = BitrateController(profile: profile)
        currentFrameRate = fps

        let fitted = CaptureSession.streamSize(
            display: DisplayEnumerator.pixelSize(of: displayID),
            device: CGSize(width: Int(device.width), height: Int(device.height))
        )
        let size = CGSize(
            width: (fitted.width * scale / 2).rounded() * 2,
            height: (fitted.height * scale / 2).rounded() * 2
        )

        do {
            try await session.send(
                .displayConfig(
                    width: UInt16(size.width),
                    height: UInt16(size.height),
                    fps: UInt8(fps),
                    codec: codec
                )
            )

            let capture = CaptureSession()
            self.capture = capture
            let frames = try await capture.start(
                provider: provider,
                pixelSize: size,
                fps: fps,
                bitrate: profile.start,
                codec: codec
            )

            injector = EventInjector(displayID: displayID)
            needsAccessibilityPermission = !AccessibilityPermission.isTrusted()
            if needsAccessibilityPermission {
                // La demande système n'apparaît qu'une fois, et l'autorisation ne prend
                // effet qu'au lancement suivant.
                AccessibilityPermission.request()
                log.error("autorisation Accessibilité manquante, les touchers seront ignorés")
            }

            streamDescription = "\(displayName) → \(Int(size.width)) × \(Int(size.height))"
            status = "diffusion en cours"
            log.info(
                """
                diffusion de \(displayName, privacy: .public) en \
                \(Int(size.width))×\(Int(size.height))
                """
            )

            streamTask = Task {
                var produced = 0
                var sent = 0
                for await frame in frames {
                    produced += 1
                    if produced % 300 == 0 {
                        log.debug("\(produced) frames encodées, \(sent) envoyées")
                    }
                    if let parameterSets = frame.parameterSets {
                        try? await session.send(.videoConfig(parameterSets: parameterSets))
                    }
                    let microseconds = UInt64(
                        max(0, CMTimeGetSeconds(frame.presentationTime) * 1_000_000)
                    )
                    do {
                        try await session.send(
                            .videoFrame(
                                timestamp: microseconds,
                                isKeyframe: frame.isKeyframe,
                                data: frame.data
                            )
                        )
                        sent += 1
                    } catch {
                        log.error("envoi de frame impossible : \(String(describing: error), privacy: .public)")
                        return
                    }
                }
                log.info("flux d'encodage terminé après \(sent) frames")
            }
        } catch {
            log.error("diffusion impossible : \(String(describing: error), privacy: .public)")
            status = "diffusion impossible : \(error)"
        }
    }

    /// Applique ce que la tablette rapporte : débit d'abord, cadence en dernier recours.
    private func applyStats(received: UInt32, dropped: UInt32) async {
        let total = received + dropped
        if total > 0 {
            dropRatePercent = Int(Double(dropped) / Double(total) * 100)
        }

        if let bitrate = bitrateController.apply(received: received, dropped: dropped) {
            await capture?.setBitrate(bitrate)
            currentBitrate = bitrate
            log.debug("débit ajusté à \(bitrate / 1_000_000) Mbit/s")
        }

        if let fps = bitrateController.suggestedFrameRate(
            current: currentFrameRate,
            received: received,
            dropped: dropped
        ), fps != currentFrameRate {
            currentFrameRate = fps
            await capture?.setFrameRate(fps)
            log.info("cadence ramenée à \(fps) fps")
        }
    }

    private func stopStreaming() async {
        streamTask?.cancel()
        streamTask = nil
        await injector?.releaseIfNeeded()
        injector = nil
        await capture?.stop()
        capture = nil
        streamDescription = nil
    }

    /// Écran désigné explicitement dans le menu, s'il est toujours là.
    private func explicitlySelectedDisplay() -> DisplayInfo? {
        guard let stored = UserDefaults.standard.object(forKey: DisplayMenuModel.selectedDisplayKey) as? Int
        else { return nil }
        let displays = (try? DisplayEnumerator.activeDisplays()) ?? []
        return displays.first { $0.id == CGDirectDisplayID(stored) }
    }

    /// Repli quand l'écran virtuel n'est pas disponible : un écran secondaire s'il y en a
    /// un, sinon l'écran principal, qu'on recopie.
    private func firstExistingDisplay() -> DisplayInfo? {
        let displays = (try? DisplayEnumerator.activeDisplays()) ?? []
        return displays.first(where: { !$0.isMain }) ?? displays.first
    }
}
