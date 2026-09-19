import CoreGraphics
import CoreMedia
import Foundation
import Observation
import SidebusCore
import os

/// Tout ce qui concerne **un** appareil : le lien, l'appairage, l'écran virtuel, la
/// capture, l'encodeur, le flux et les entrées.
///
/// Une instance par appareil en partage. Elles ne partagent rien : chacune a sa connexion,
/// son écran virtuel, son encodeur matériel et son contrôleur de débit. C'est ce qui rend
/// le partage vers plusieurs tablettes possible sans état commun à arbitrer.
///
/// La découverte, elle, reste chez `DeviceManager` : elle est globale par nature.
@MainActor
@Observable
final class DeviceSession {

    /// Ce que la session est venue faire.
    enum Mode: Sendable {
        /// Se connecter le temps d'échanger l'appairage, puis raccrocher.
        case pairing
        /// Se connecter et diffuser, en se reconnectant tant que l'appareil est visible.
        case sharing
    }

    enum Phase: Equatable {
        case connecting
        /// Les deux côtés doivent confirmer : le Mac l'a fait, la tablette pas encore.
        case awaitingRemotePairing(code: String)
        case connected
        case streaming
        case stopped(String)
        case failed(String)
    }

    /// Clé de l'appareil : son identifiant persistant quand il est connu, sinon la clé de
    /// découverte. Voir `DeviceManager.key(for:)`.
    private(set) var key: String
    let mode: Mode

    private(set) var phase: Phase = .connecting
    private(set) var peer: Peer
    private(set) var deviceName: String?
    private(set) var deviceResolution: String?
    private(set) var roundTripMilliseconds: Double?
    private(set) var streamDescription: String?
    private(set) var currentBitrate: Int?
    private(set) var dropRatePercent: Int?

    /// Vrai quand l'écran virtuel a échoué et qu'on recopie un écran existant.
    private(set) var usesFallbackDisplay = false

    /// Vrai quand l'autorisation Accessibilité manque : les touchers sont alors reçus mais
    /// ne produisent rien.
    private(set) var needsAccessibilityPermission = false

    @ObservationIgnored
    let pairing = PairingValidator()

    @ObservationIgnored
    private let macName: String
    @ObservationIgnored
    private let macUUID: UUID
    @ObservationIgnored
    private let watcher: AdbWatcher
    /// Meilleur pair connu pour une clé à l'instant présent, ou `nil` si l'appareil a
    /// disparu. La clé est passée à chaque appel plutôt que capturée : elle change quand
    /// DEVICE_INFO révèle l'identifiant persistant, et une clé figée ferait chercher un
    /// appareil qui n'existe plus sous ce nom.
    @ObservationIgnored
    private let peerForKey: @MainActor (String) -> Peer?
    @ObservationIgnored
    private let onIdentified: @MainActor (UUID, PeerSession.DeviceDescription, Peer) -> Void
    @ObservationIgnored
    private let onFinished: @MainActor (DeviceSession) -> Void

    @ObservationIgnored
    private var task: Task<Void, Never>?
    @ObservationIgnored
    private var session: PeerSession?
    @ObservationIgnored
    private var capture: CaptureSession?
    @ObservationIgnored
    private var streamTask: Task<Void, Never>?
    @ObservationIgnored
    private var injector: EventInjector?
    @ObservationIgnored
    private var bitrateController = BitrateController(profile: .usb)
    @ObservationIgnored
    private var currentFrameRate = 60
    @ObservationIgnored
    private var byeReason: ByeReason = .normal

    /// Appareil identifié, en attente du PAIR_RESULT de la tablette.
    @ObservationIgnored
    private var pendingDevice: PeerSession.DeviceDescription?
    @ObservationIgnored
    private var pairingTimeout: Task<Void, Never>?

    @ObservationIgnored
    private let log = Logger(subsystem: "app.sidebus", category: "session")

    init(
        key: String,
        mode: Mode,
        peer: Peer,
        macName: String,
        macUUID: UUID,
        watcher: AdbWatcher,
        peerForKey: @escaping @MainActor (String) -> Peer?,
        onIdentified: @escaping @MainActor (UUID, PeerSession.DeviceDescription, Peer) -> Void,
        onFinished: @escaping @MainActor (DeviceSession) -> Void
    ) {
        self.key = key
        self.mode = mode
        self.peer = peer
        self.macName = macName
        self.macUUID = macUUID
        self.watcher = watcher
        self.peerForKey = peerForKey
        self.onIdentified = onIdentified
        self.onFinished = onFinished
    }

    /// Réaffecte la clé quand DEVICE_INFO révèle l'identifiant persistant d'une tablette
    /// jusque là connue par son seul numéro de série adb.
    func adopt(key newKey: String) {
        key = newKey
    }

    var isStreaming: Bool { phase == .streaming }

    /// Résumé d'une ligne, affiché sous le nom dans le menu.
    var detail: String? {
        switch phase {
        case .connecting:
            return "connexion…"
        case let .awaitingRemotePairing(code):
            return "confirmez le code \(code) sur la tablette"
        case .connected:
            return "connecté, préparation du flux"
        case .streaming:
            var parts: [String] = []
            if let streamDescription { parts.append(streamDescription) }
            if let roundTripMilliseconds {
                parts.append(String(format: "%.1f ms", roundTripMilliseconds))
            }
            if let currentBitrate {
                parts.append(String(format: "%.1f Mbit/s", Double(currentBitrate) / 1_000_000))
            }
            if let dropRatePercent, dropRatePercent > 0 {
                parts.append("\(dropRatePercent) % droppées")
            }
            if usesFallbackDisplay {
                parts.append("écran virtuel indisponible, recopie d'un écran existant")
            }
            if needsAccessibilityPermission {
                parts.append("Accessibilité refusée, le tactile est ignoré")
            }
            return parts.joined(separator: ", ")
        case let .stopped(reason), let .failed(reason):
            return reason
        }
    }

    // MARK: - Cycle de vie

    func start() {
        guard task == nil else { return }
        task = Task { await self.loop() }
    }

    /// Arrête la session. `reason` part dans le BYE, pour que la tablette distingue une
    /// bascule de transport d'un arrêt voulu.
    func stop(bye: ByeReason = .normal, status: String) async {
        byeReason = bye
        task?.cancel()
        task = nil

        let previous = session
        session = nil
        if let previous {
            try? await previous.send(.bye(reason: bye))
            await previous.stop(reason: status)
        }
        // Une demande d'appairage restée sans réponse : ne pas laisser la continuation
        // pendante, elle bloquerait la boucle.
        pairingTimeout?.cancel()
        pairingTimeout = nil
        pendingDevice = nil
        await stopStreaming()
        phase = .stopped(status)
    }

    private func loop() async {
        var failures = 0

        while !Task.isCancelled {
            guard let peer = peerForKey(key) else { break }
            self.peer = peer

            let sawDeviceInfo = await runOnce(peer: peer)

            if mode == .pairing { break }
            if case .failed = phase, pairing.awaitsRemoteConfirmation == false,
                pairing.lastRefusal != nil {
                // Appairage refusé d'un côté ou de l'autre : insister ne servirait qu'à
                // reposer la question en boucle.
                break
            }
            guard !Task.isCancelled else { break }

            // Jamais de DEVICE_INFO en USB : l'application n'est pas au premier plan sur
            // la tablette. On la lance et on réessaie. En Wi-Fi il n'y a rien à lancer,
            // l'annonce ne vit que quand l'app tourne.
            if !sawDeviceInfo, peer.kind == .usb, failures == 0 {
                phase = .connecting
                log.info("aucun DEVICE_INFO, lancement de l'app sur \(peer.id, privacy: .public)")
                try? await watcher.launchApp(serial: peer.id)
                try? await Task.sleep(for: .seconds(1.5))
                failures += 1
                continue
            }

            guard peerForKey(key) != nil else { break }

            // Backoff exponentiel, plafonné : une tablette éteinte ne doit pas faire
            // tourner une boucle de reconnexion à vide.
            failures = sawDeviceInfo ? 0 : failures + 1
            let seconds = min(30, Int(pow(2.0, Double(min(failures, 5)))))
            log.debug("nouvelle tentative dans \(seconds) s")
            try? await Task.sleep(for: .seconds(seconds))
        }

        await stopStreaming()
        task = nil
        onFinished(self)
    }

    /// Une tentative de connexion. Renvoie vrai si DEVICE_INFO est passé.
    private func runOnce(peer: Peer) async -> Bool {
        var sawDeviceInfo = false
        phase = .connecting
        log.info("connexion à \(peer.name, privacy: .public) en \(peer.kind.rawValue, privacy: .public)")

        do {
            if peer.kind == .usb {
                try await watcher.forward(
                    serial: peer.id,
                    localPort: Sidebus.port,
                    devicePort: Sidebus.port
                )
            }

            // La connexion TCP réussit toujours en USB : adb accepte en local même si rien
            // n'écoute sur l'appareil. C'est l'absence de DEVICE_INFO qui dit que
            // l'application n'est pas lancée.
            //
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
                await transport.close()
                return sawDeviceInfo
            } catch {
                await transport.close()
                if case TransportError.timedOut = error, peer.kind == .wifi {
                    // Le réseau accepte l'annonce mais laisse tomber les paquets : c'est
                    // la signature de l'isolation des clients, qu'aucun code ne contourne.
                    phase = .failed(
                        """
                        annoncée mais injoignable, le réseau isole probablement ses \
                        appareils entre eux
                        """
                    )
                    log.error("\(peer.name, privacy: .public) injoignable, isolation probable")
                    return sawDeviceInfo
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
                    deviceName = device.name
                    deviceResolution = "\(device.width) × \(device.height)"
                    phase = .connected
                    log.info(
                        """
                        connecté à \(device.name, privacy: .public), \
                        \(device.width)×\(device.height), \(device.density) dpi, \
                        codecs 0x\(String(device.codecs, radix: 16), privacy: .public)
                        """
                    )

                    if await requestRemotePairing(device: device, session: session) {
                        // La suite attend PAIR_RESULT, qui arrive par cette même boucle.
                        pendingDevice = device
                    } else {
                        await proceed(with: device, session: session, peer: peer)
                    }

                case let .roundTrip(milliseconds):
                    roundTripMilliseconds = milliseconds

                case let .received(message):
                    await handle(message, session: session, peer: peer)

                case let .closed(reason):
                    log.info("session fermée : \(reason, privacy: .public)")
                    await stopStreaming()
                    roundTripMilliseconds = nil
                    if case .failed = phase {} else { phase = .stopped(reason) }
                }
            }
        } catch is CancellationError {
            await stopStreaming()
            return sawDeviceInfo
        } catch {
            log.error("connexion échouée : \(String(describing: error), privacy: .public)")
            phase = .failed("\(error)")
        }

        await stopStreaming()
        session = nil
        return sawDeviceInfo
    }

    private func handle(_ message: Message, session: PeerSession, peer: Peer) async {
        switch message {
        case let .stats(received, dropped, _):
            await applyStats(received: received, dropped: dropped)

        case .keyframeRequest:
            // Le décodeur a perdu le fil : sans keyframe il reste noir jusqu'à la
            // prochaine, soit cinq secondes.
            await capture?.requestKeyframe()

        case let .inputEvent(kind, x, y, button, _):
            await injector?.inject(kind: kind, x: x, y: y, button: button)

        case let .pairResult(accepted):
            await completePairing(accepted: accepted, session: session, peer: peer)

        default:
            log.debug("message \(message.type) reçu")
        }
    }

    // MARK: - Appairage

    /// Second temps de l'appairage : la tablette doit confirmer à son tour.
    ///
    /// N'a lieu que si le Mac vient d'accepter une empreinte inconnue. Un appareil déjà
    /// appairé ne repasse jamais par là.
    ///
    /// Renvoie vrai quand la demande est partie, donc quand la suite attend PAIR_RESULT.
    /// L'attente ne bloque surtout pas la boucle d'événements : c'est elle qui apportera la
    /// réponse, et l'y bloquer serait un interblocage franc.
    private func requestRemotePairing(
        device: PeerSession.DeviceDescription,
        session: PeerSession
    ) async -> Bool {
        guard pairing.awaitsRemoteConfirmation, let code = pairing.pendingCode else { return false }

        let printable = PairingCode.format(code)
        phase = .awaitingRemotePairing(code: printable)
        log.info("PAIR_REQUEST envoyé, code \(printable, privacy: .public)")

        do {
            try await session.send(.pairRequest(code: code))
        } catch {
            pairing.discardPending(reason: "demande d'appairage non transmise : \(error)")
            phase = .failed("demande d'appairage non transmise")
            await session.stop(reason: "appairage impossible")
            return false
        }

        // 120 s, comme le protocole l'impose. C'est le temps qu'il faut pour aller chercher
        // la tablette dans l'autre pièce.
        pairingTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(120))
            guard !Task.isCancelled else { return }
            await self?.pairingTimedOut(session: session)
        }
        return true
    }

    private func pairingTimedOut(session: PeerSession) async {
        guard pendingDevice != nil else { return }
        pendingDevice = nil
        pairing.discardPending(reason: "la tablette n'a pas répondu à la demande d'appairage")
        phase = .failed("la tablette n'a pas répondu")
        try? await session.send(.bye(reason: .normal))
        await session.stop(reason: "appairage sans réponse")
    }

    /// PAIR_RESULT reçu : les deux côtés se sont prononcés.
    private func completePairing(accepted: Bool, session: PeerSession, peer: Peer) async {
        pairingTimeout?.cancel()
        pairingTimeout = nil

        guard let device = pendingDevice else { return }
        pendingDevice = nil

        guard accepted else {
            pairing.discardPending(reason: "appairage refusé sur la tablette")
            phase = .failed("appairage refusé sur la tablette")
            await session.stop(reason: "appairage refusé")
            return
        }

        do {
            try pairing.commitPending(deviceID: device.uuid)
        } catch {
            pairing.discardPending(reason: "enregistrement impossible : \(error)")
            phase = .failed("enregistrement dans le trousseau impossible")
            await session.stop(reason: "trousseau inaccessible")
            return
        }

        await proceed(with: device, session: session, peer: peer)
    }

    /// Appareil identifié et appairé : on enchaîne sur ce que la session est venue faire.
    private func proceed(
        with device: PeerSession.DeviceDescription,
        session: PeerSession,
        peer: Peer
    ) async {
        onIdentified(device.uuid, device, peer)

        guard mode == .sharing else {
            try? await session.send(.bye(reason: .normal))
            await session.stop(reason: "appairage terminé")
            phase = .stopped("appairé")
            return
        }
        await startStreaming(to: device, session: session, peer: peer)
    }

    // MARK: - Diffusion

    /// Démarre la capture et pousse le flux sur le lien : DISPLAY_CONFIG, puis
    /// VIDEO_CONFIG à la première frame, puis les VIDEO_FRAME.
    private func startStreaming(
        to device: PeerSession.DeviceDescription,
        session: PeerSession,
        peer: Peer
    ) async {
        await stopStreaming()

        guard ScreenCapturer.isAuthorized() else {
            ScreenCapturer.requestAuthorization()
            phase = .failed("autorisation Enregistrement de l'écran manquante")
            return
        }

        let provider: any VirtualDisplayProvider
        let displayID: CGDirectDisplayID
        let displayName: String

        if let chosen = Self.explicitlySelectedDisplay() {
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
                        name: "Sidebus \(device.name)"
                    )
                )
                displayID = try await virtual.acquire()
                provider = virtual
                displayName = "écran virtuel"
            } catch {
                // L'API est privée : elle peut casser à n'importe quelle version de macOS.
                // On le dit, et on retombe sur un écran existant plutôt que d'échouer.
                log.error(
                    """
                    écran virtuel indisponible \
                    (\(String(describing: error), privacy: .public)), repli
                    """
                )
                guard let fallback = Self.firstExistingDisplay() else {
                    phase = .failed("aucun écran à capturer")
                    return
                }
                provider = ExistingDisplayProvider(targetID: fallback.id)
                displayID = fallback.id
                displayName = "\(fallback.name) (repli)"
                usesFallbackDisplay = true
            }
        }

        let environment = ProcessInfo.processInfo.environment
        // Défaut plus prudent en Wi-Fi : moins de pixels à transporter sur un lien qu'on
        // ne maîtrise pas.
        let defaultScale = peer.kind == .wifi ? 0.75 : 1.0
        let scale = environment["SIDEBUS_CAPTURE_SCALE"].flatMap(Double.init)
            ?? UserDefaults.standard.object(forKey: DeviceManager.resolutionScaleKey) as? Double
            ?? defaultScale
        let fps = environment["SIDEBUS_FPS"].flatMap(Int.init) ?? 60

        // HEVC dès que la tablette l'annonce : mesuré à 0,5 Mbit/s contre 1,4 en H.264 sur
        // le même contenu, décodé en matériel sans une frame perdue.
        //
        // Attention aux décodeurs logiciels, celui de l'émulateur Android en particulier :
        // il rend des chromas cassées, blocs verts et magenta, là où H.264 passe. D'où
        // SIDEBUS_CODEC=h264, qui force le repli.
        let requested = environment["SIDEBUS_CODEC"]
        let codec: Codec = (requested != "h264" && device.supportsHEVC) ? .hevc : .h264
        let profile: BitrateController.Profile = peer.kind == .usb ? .usb : .wifi
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
            phase = .streaming
            log.info(
                """
                diffusion de \(displayName, privacy: .public) en \
                \(Int(size.width))×\(Int(size.height))
                """
            )

            streamTask = Task { await self.pump(frames: frames, session: session) }
        } catch {
            log.error("diffusion impossible : \(String(describing: error), privacy: .public)")
            phase = .failed("diffusion impossible : \(error)")
        }
    }

    private func pump(frames: AsyncStream<EncodedFrame>, session: PeerSession) async {
        var sent = 0
        for await frame in frames {
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

        // La capture s'est arrêtée alors que le lien tient : c'est macOS qui l'a coupée,
        // presque toujours parce que l'utilisateur a cliqué « Arrêter le partage » dans le
        // Centre de contrôle. C'est une intention explicite, propre à cet appareil : on
        // arrête son partage, sinon la reconnexion relance la capture dans la seconde et le
        // geste n'a servi à rien.
        //
        // Sauf si la tâche a été annulée : dans ce cas une autre diffusion a déjà pris la
        // place, et démonter ici tuerait la session suivante.
        log.info("flux d'encodage terminé après \(sent) frames")
        guard !Task.isCancelled, phase == .streaming else { return }
        log.info("capture coupée par macOS, arrêt du partage")
        systemStoppedCapture?(self)
    }

    /// Appelé quand macOS coupe la capture. `DeviceManager` s'en sert pour retirer
    /// l'intention de partage, sans quoi la reconnexion la relancerait aussitôt.
    @ObservationIgnored
    var systemStoppedCapture: (@MainActor (DeviceSession) -> Void)?

    /// Applique ce que la tablette rapporte : débit d'abord, cadence en dernier recours.
    private func applyStats(received: UInt32, dropped: UInt32) async {
        let total = received + dropped
        if total > 0 {
            dropRatePercent = Int(Double(dropped) / Double(total) * 100)
        }

        if let bitrate = bitrateController.apply(received: received, dropped: dropped) {
            await capture?.setBitrate(bitrate)
            currentBitrate = bitrate
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

    /// Écran désigné explicitement dans les réglages, s'il est toujours là.
    private static func explicitlySelectedDisplay() -> DisplayInfo? {
        guard let stored = UserDefaults.standard.object(forKey: DisplayMenuModel.selectedDisplayKey) as? Int
        else { return nil }
        let displays = (try? DisplayEnumerator.activeDisplays()) ?? []
        return displays.first { $0.id == CGDirectDisplayID(stored) }
    }

    /// Repli quand l'écran virtuel n'est pas disponible : un écran secondaire s'il y en a
    /// un, sinon l'écran principal, qu'on recopie.
    private static func firstExistingDisplay() -> DisplayInfo? {
        let displays = (try? DisplayEnumerator.activeDisplays()) ?? []
        return displays.first(where: { !$0.isMain }) ?? displays.first
    }
}
