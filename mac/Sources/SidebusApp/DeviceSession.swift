import CoreGraphics
import CoreImage
import CoreMedia
import Foundation
import Observation
import SidebusCore
import os

/// Everything about **one** device: the link, pairing, the virtual display, capture, the
/// encoder, the stream and the input events.
///
/// One instance per shared device. They share nothing: each has its own connection, virtual
/// display, hardware encoder and bitrate controller. That is what makes sharing to several
/// tablets possible with no common state to arbitrate.
///
/// Discovery stays with `DeviceManager`, being global by nature.
private let cameraLog = Logger(subsystem: "app.sidebus", category: "camera")

@MainActor
@Observable
final class DeviceSession {

    /// What the session came to do.
    enum Mode: Sendable {
        /// Connect long enough to exchange the pairing, then hang up.
        case pairing
        /// Connect and stay, reconnecting while the device stays visible. What the link
        /// carries, screen or camera or both, is `sharesScreen` and `wantedCamera`.
        case live
    }

    /// Which camera the Mac wants running on this device.
    enum CameraChoice: Equatable, Sendable {
        case id(UInt8)
        /// Whatever the tablet offers first, its back camera by preference. Used when the
        /// list is not known yet, which is the case before the first connection.
        case preferred
    }

    enum Phase: Equatable {
        case connecting
        /// Both sides must confirm: the Mac has, the tablet has not yet.
        case awaitingRemotePairing(code: String)
        case connected
        case streaming
        case stopped(String)
        case failed(String)
    }

    /// Device key: its persistent identifier when known, otherwise the discovery key. See
    /// `DeviceManager.key(for:)`.
    private(set) var key: String
    let mode: Mode

    /// True when this link is carrying the Mac's screen. Independent of the camera: either
    /// can run without the other, on the same connection.
    private(set) var sharesScreen: Bool

    /// Camera the Mac wants from this device, kept across reconnections.
    private(set) var wantedCamera: CameraChoice?

    private(set) var phase: Phase = .connecting
    private(set) var peer: Peer
    private(set) var deviceName: String?
    private(set) var deviceResolution: String?
    private(set) var roundTripMilliseconds: Double?
    private(set) var streamDescription: String?
    private(set) var currentBitrate: Int?
    private(set) var dropRatePercent: Int?

    /// True when the virtual display failed and an existing display is mirrored instead.
    private(set) var usesFallbackDisplay = false

    /// True when the Accessibility permission is missing: touches arrive but produce
    /// nothing.
    private(set) var needsAccessibilityPermission = false

    /// Cameras the tablet announced, from CAMERA_LIST. Empty until it says otherwise.
    private(set) var cameras: [CameraDescription] = []

    /// Camera currently being received, if any.
    private(set) var activeCamera: CameraDescription?

    /// Last decoded camera frame, for the preview window.
    private(set) var cameraFrame: CapturedFrame?

    /// Description of the camera stream, for the preview window's title.
    private(set) var cameraDescription: String?

    /// Quarter turns clockwise to apply to the camera picture, from CAMERA_CONFIG.
    private(set) var cameraRotation: Int = 0

    /// Set when CAMERA_START brought nothing back. The tablet has no way to say why, so
    /// this names the likely reason rather than leave the user with a black window.
    private(set) var cameraProblem: String?

    @ObservationIgnored
    let pairing = PairingValidator()

    @ObservationIgnored
    private let macName: String
    @ObservationIgnored
    private let macUUID: UUID
    @ObservationIgnored
    private let watcher: AdbWatcher
    /// Best known peer for a key right now, or `nil` when the device has gone. The key is
    /// passed on every call rather than captured: it changes when DEVICE_INFO reveals the
    /// persistent identifier, and a frozen key would look for a device that no longer
    /// exists under that name.
    @ObservationIgnored
    private let peerForKey: @MainActor (String) -> Peer?
    @ObservationIgnored
    private let onIdentified: @MainActor (UUID, PeerSession.DeviceDescription, Peer) -> Void
    /// CAMERA_LIST received. `DeviceManager` records it so the menu can offer the cameras
    /// of a device that is not connected.
    @ObservationIgnored
    private let onCameras: @MainActor (String, [CameraDescription]) -> Void
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

    /// Device identified, waiting for the tablet's PAIR_RESULT.
    @ObservationIgnored
    private var pendingDevice: PeerSession.DeviceDescription?
    @ObservationIgnored
    private var pairingTimeout: Task<Void, Never>?
    @ObservationIgnored
    private var cameraDecoder: CameraDecoder?
    @ObservationIgnored
    private var cameraTask: Task<Void, Never>?
    @ObservationIgnored
    private var cameraWatchdog: Task<Void, Never>?
    /// What is needed to start or stop the screen stream after the fact, once the link is
    /// up. Set the moment the device is identified and paired.
    @ObservationIgnored
    private var liveDevice: PeerSession.DeviceDescription?
    @ObservationIgnored
    private var livePeer: Peer?
    /// The configuration the decoder is running on, so a CAMERA_CONFIG that only brings a
    /// new rotation does not tear it down.
    @ObservationIgnored
    private var cameraSetup: (width: Int, height: Int, codec: Codec, parameterSets: Data)?

    @ObservationIgnored
    private let log = Logger(subsystem: "app.sidebus", category: "session")

    init(
        key: String,
        mode: Mode,
        peer: Peer,
        sharesScreen: Bool = false,
        wantedCamera: CameraChoice? = nil,
        macName: String,
        macUUID: UUID,
        watcher: AdbWatcher,
        peerForKey: @escaping @MainActor (String) -> Peer?,
        onIdentified: @escaping @MainActor (UUID, PeerSession.DeviceDescription, Peer) -> Void,
        onCameras: @escaping @MainActor (String, [CameraDescription]) -> Void,
        onFinished: @escaping @MainActor (DeviceSession) -> Void
    ) {
        self.key = key
        self.mode = mode
        self.peer = peer
        self.sharesScreen = sharesScreen
        self.wantedCamera = wantedCamera
        self.macName = macName
        self.macUUID = macUUID
        self.watcher = watcher
        self.peerForKey = peerForKey
        self.onIdentified = onIdentified
        self.onCameras = onCameras
        self.onFinished = onFinished
    }

    /// Reassigns the key when DEVICE_INFO reveals the persistent identifier of a tablet
    /// known so far by its adb serial alone.
    func adopt(key newKey: String) {
        key = newKey
    }

    var isStreaming: Bool { phase == .streaming }

    /// One line summary, shown under the name in the menu.
    var detail: String? {
        switch phase {
        case .connecting:
            return "connecting…"
        case let .awaitingRemotePairing(code):
            return "confirm code \(code) on the tablet"
        case .connected:
            if sharesScreen { return "connected, preparing the stream" }
            if let cameraProblem { return cameraProblem }
            if activeCamera != nil {
                return [cameraDescription, "camera"].compactMap { $0 }.joined(separator: ", ")
            }
            return wantedCamera != nil ? "connected, opening the camera" : "connected"
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
                parts.append("\(dropRatePercent) % dropped")
            }
            if usesFallbackDisplay {
                parts.append("virtual display unavailable, mirroring an existing one")
            }
            if needsAccessibilityPermission {
                parts.append("Accessibility refused, touch is ignored")
            }
            if let cameraProblem { parts.append(cameraProblem) }
            return parts.joined(separator: ", ")
        case let .stopped(reason), let .failed(reason):
            return reason
        }
    }

    // MARK: - Lifecycle

    func start() {
        guard task == nil else { return }
        task = Task { await self.loop() }
    }

    /// Stops the session. `reason` goes into the BYE, so the tablet can tell a transport
    /// switch from a deliberate stop.
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
        // A pairing request left unanswered: do not leave the wait hanging, it would block
        // the loop.
        pairingTimeout?.cancel()
        pairingTimeout = nil
        pendingDevice = nil
        stopCamera()
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
                // Pairing refused on one side or the other: insisting would only ask the
                // question again in a loop.
                break
            }
            guard !Task.isCancelled else { break }

            // No DEVICE_INFO on USB means the app is not in the foreground on the tablet.
            // Start it and try again. On Wi-Fi there is nothing to start, the
            // advertisement only lives while the app runs.
            if !sawDeviceInfo, peer.kind == .usb, failures == 0 {
                phase = .connecting
                log.info("no DEVICE_INFO, starting the app on \(peer.id, privacy: .public)")
                try? await watcher.launchApp(serial: peer.id)
                try? await Task.sleep(for: .seconds(1.5))
                failures += 1
                continue
            }

            guard peerForKey(key) != nil else { break }

            // Exponential backoff, capped: a tablet that is off must not spin a reconnection
            // loop for nothing.
            failures = sawDeviceInfo ? 0 : failures + 1
            let seconds = min(30, Int(pow(2.0, Double(min(failures, 5)))))
            log.debug("retrying in \(seconds) s")
            try? await Task.sleep(for: .seconds(seconds))
        }

        await stopStreaming()
        task = nil
        onFinished(self)
    }

    /// One connection attempt. Returns true when DEVICE_INFO came through.
    private func runOnce(peer: Peer) async -> Bool {
        var sawDeviceInfo = false
        phase = .connecting
        log.info("connecting to \(peer.name, privacy: .public) over \(peer.kind.rawValue, privacy: .public)")

        do {
            if peer.kind == .usb {
                try await watcher.forward(
                    serial: peer.id,
                    localPort: Sidebus.port,
                    devicePort: Sidebus.port
                )
            }

            // The TCP connection always succeeds on USB: adb accepts locally even when nothing
            // listens on the device. It is the absence of DEVICE_INFO that says the app is
            // not running.
            //
            // Encryption stays on over USB: one code path to maintain and to test, and the
            // cost of TLS 1.3 is negligible next to video encoding.
            let transport = TransportClient(
                endpoint: peer.endpoint,
                kind: peer.kind,
                validator: pairing,
                expectedDeviceID: peer.deviceID?.uuidString
            )
            do {
                try await withTimeout(
                    .seconds(8),
                    suspendedWhile: { [pairing] in await pairing.isAskingUser }
                ) { try await transport.connect() }
            } catch is CancellationError {
                await transport.close()
                return sawDeviceInfo
            } catch {
                await transport.close()
                if case TransportError.timedOut = error, peer.kind == .wifi {
                    // The network accepts the advertisement but drops the packets, the signature
                    // of client isolation, which no code works around.
                    phase = .failed(
                        """
                        advertised but unreachable, the network probably isolates its \
                        devices from each other
                        """
                    )
                    log.error("\(peer.name, privacy: .public) unreachable, isolation likely")
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
                        connected to \(device.name, privacy: .public), \
                        \(device.width)×\(device.height), \(device.density) dpi, \
                        codecs 0x\(String(device.codecs, radix: 16), privacy: .public)
                        """
                    )

                    if await requestRemotePairing(device: device, session: session) {
                        // The rest waits for PAIR_RESULT, which arrives through this very loop.
                        pendingDevice = device
                    } else {
                        await proceed(with: device, session: session, peer: peer)
                    }

                case let .roundTrip(milliseconds):
                    roundTripMilliseconds = milliseconds

                case let .received(message):
                    await handle(message, session: session, peer: peer)

                case let .closed(reason):
                    log.info("session closed: \(reason, privacy: .public)")
                    liveDevice = nil
                    livePeer = nil
                    await stopStreaming()
                    roundTripMilliseconds = nil
                    if case .failed = phase {} else { phase = .stopped(reason) }
                }
            }
        } catch is CancellationError {
            await stopStreaming()
            return sawDeviceInfo
        } catch {
            log.error("connection failed: \(String(describing: error), privacy: .public)")
            phase = .failed("\(error)")
        }

        await stopStreaming()
        // The camera has to be asked for again on the next connection, but the intent
        // survives: `wantedCamera` is left alone on purpose.
        activeCamera = nil
        cameraFrame = nil
        cameraSetup = nil
        liveDevice = nil
        livePeer = nil
        session = nil
        return sawDeviceInfo
    }

    private func handle(_ message: Message, session: PeerSession, peer: Peer) async {
        switch message {
        case let .stats(received, dropped, _):
            await applyStats(received: received, dropped: dropped)

        case .keyframeRequest:
            // The decoder lost the thread: without a keyframe it stays black until the next
            // one, five seconds away.
            await capture?.requestKeyframe()

        case let .inputEvent(kind, x, y, button, _):
            await injector?.inject(kind: kind, x: x, y: y, button: button)

        case let .pairResult(accepted):
            await completePairing(accepted: accepted, session: session, peer: peer)

        case let .cameraList(list):
            cameras = list
            onCameras(key, list)
            log.info("tablet offers \(list.count) camera(s)")
            applyCameraIntent()

        case let .cameraConfig(width, height, codec, rotation, parameterSets):
            Self.appendRawIfRequested(parameterSets)
            await startCameraDecoder(
                width: Int(width),
                height: Int(height),
                codec: codec,
                rotation: Int(rotation),
                parameterSets: parameterSets
            )

        case let .cameraFrame(timestamp, _, data):
            Self.appendRawIfRequested(data)
            try? await cameraDecoder?.decode(data, timestamp: timestamp)

        default:
            log.debug("message \(message.type) received")
        }
    }

    // MARK: - Pairing

    /// Second step of pairing: the tablet has to confirm in turn.
    ///
    /// Only happens when the Mac has just accepted an unknown fingerprint. An already paired
    /// device never comes through here.
    ///
    /// Returns true once the request has gone out, so once the rest waits for PAIR_RESULT.
    /// That wait must not block the event loop: the loop is what brings the answer, and
    /// blocking it there would be a plain deadlock.
    private func requestRemotePairing(
        device: PeerSession.DeviceDescription,
        session: PeerSession
    ) async -> Bool {
        guard pairing.awaitsRemoteConfirmation, let code = pairing.pendingCode else { return false }

        let printable = PairingCode.format(code)
        phase = .awaitingRemotePairing(code: printable)
        log.info("PAIR_REQUEST sent, code \(printable, privacy: .public)")

        do {
            try await session.send(.pairRequest(code: code))
        } catch {
            pairing.discardPending(reason: "pairing request not delivered: \(error)")
            phase = .failed("pairing request not delivered")
            await session.stop(reason: "pairing impossible")
            return false
        }

        // 120 s, as the protocol requires. That is the time it takes to fetch the tablet from
        // the other room.
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
        pairing.discardPending(reason: "the tablet did not answer the pairing request")
        phase = .failed("the tablet did not answer")
        try? await session.send(.bye(reason: .normal))
        await session.stop(reason: "pairing unanswered")
    }

    /// PAIR_RESULT received: both sides have spoken.
    private func completePairing(accepted: Bool, session: PeerSession, peer: Peer) async {
        pairingTimeout?.cancel()
        pairingTimeout = nil

        guard let device = pendingDevice else { return }
        pendingDevice = nil

        guard accepted else {
            pairing.discardPending(reason: "pairing refused on the tablet")
            phase = .failed("pairing refused on the tablet")
            await session.stop(reason: "pairing refused")
            return
        }

        do {
            try pairing.commitPending(deviceID: device.uuid)
        } catch {
            pairing.discardPending(reason: "cannot record: \(error)")
            phase = .failed("cannot record in the keychain")
            await session.stop(reason: "keychain unreachable")
            return
        }

        await proceed(with: device, session: session, peer: peer)
    }

    /// Device identified and paired: carry on with what the session came to do.
    private func proceed(
        with device: PeerSession.DeviceDescription,
        session: PeerSession,
        peer: Peer
    ) async {
        onIdentified(device.uuid, device, peer)

        guard mode == .live else {
            // A pairing session hangs up as soon as it is done. CAMERA_LIST travels with
            // DEVICE_INFO, so waiting a moment is what makes the tablet's cameras known
            // before the first share, and the menu can offer them straight away.
            try? await Task.sleep(for: .milliseconds(300))
            try? await session.send(.bye(reason: .normal))
            await session.stop(reason: "pairing done")
            phase = .stopped("paired")
            return
        }

        liveDevice = device
        livePeer = peer

        if sharesScreen {
            await startStreaming(to: device, session: session, peer: peer)
        }
        applyCameraIntent()
    }

    // MARK: - Intents

    /// Starts or stops the screen stream on a link that is already up.
    ///
    /// The camera is not touched: the two intents share one connection and nothing else.
    func setScreenSharing(_ on: Bool) {
        guard sharesScreen != on else { return }
        sharesScreen = on

        guard mode == .live, let session, let device = liveDevice, let peer = livePeer else {
            return
        }
        Task {
            if on {
                await startStreaming(to: device, session: session, peer: peer)
            } else {
                await stopStreaming()
                // Silence would not do: nothing is encoded while the shared screen holds
                // still, so the tablet cannot tell an idle stream from one that has ended.
                try? await session.send(.videoStop)
                if phase == .streaming { phase = .connected }
                log.info("screen sharing stopped, link kept for the camera")
            }
        }
    }

    /// Asks for a camera, now or as soon as the link is up.
    func requestCamera(_ choice: CameraChoice) {
        wantedCamera = choice
        applyCameraIntent()
    }

    /// Sends CAMERA_START once the link is live and the wanted camera is on the list.
    private func applyCameraIntent() {
        guard mode == .live, liveDevice != nil, let choice = wantedCamera else { return }
        guard let camera = resolve(choice) else { return }
        guard activeCamera != camera else { return }
        startCamera(camera)
    }

    /// The camera a choice points at, `nil` while CAMERA_LIST has not arrived.
    private func resolve(_ choice: CameraChoice) -> CameraDescription? {
        switch choice {
        case let .id(id):
            return cameras.first { $0.id == id }
        case .preferred:
            return cameras.first { $0.facing == .back } ?? cameras.first
        }
    }

    // MARK: - Camera

    /// Asks the tablet to open one of its cameras and send it back.
    ///
    /// The opposite direction from the screen stream, on the same socket. A tablet propped
    /// up as a display rarely points at anything worth filming, so this is meant for a
    /// second device rather than the one showing the screen.
    func startCamera(_ camera: CameraDescription, width: Int = 1280, height: Int = 720, fps: Int = 30) {
        guard let session else { return }
        wantedCamera = .id(camera.id)
        activeCamera = camera
        cameraProblem = nil
        armCameraWatchdog()
        log.info("CAMERA_START \(camera.label, privacy: .public)")
        Task {
            try? await session.send(
                .cameraStart(
                    id: camera.id,
                    width: UInt16(width),
                    height: UInt16(height),
                    fps: UInt8(fps),
                    codec: .h264
                )
            )
        }
    }

    func stopCamera() {
        wantedCamera = nil
        cameraWatchdog?.cancel()
        cameraWatchdog = nil
        cameraProblem = nil
        guard activeCamera != nil else { return }
        log.info("CAMERA_STOP")
        let session = self.session
        activeCamera = nil
        cameraFrame = nil
        cameraDescription = nil
        cameraSetup = nil
        cameraRotation = 0
        cameraTask?.cancel()
        cameraTask = nil
        let decoder = cameraDecoder
        cameraDecoder = nil
        Task {
            try? await session?.send(.cameraStop)
            await decoder?.stop()
        }
    }

    private func startCameraDecoder(
        width: Int,
        height: Int,
        codec: Codec,
        rotation: Int,
        parameterSets: Data
    ) async {
        // The tablet sends CAMERA_CONFIG again every time it is turned. Same stream, new
        // angle: rebuilding the decoder would blank the picture until the next keyframe,
        // for a change that costs one transform on the layer.
        if let current = cameraSetup,
            current.width == width,
            current.height == height,
            current.codec == codec,
            current.parameterSets == parameterSets
        {
            cameraRotation = rotation
            cameraProblem = nil
            cameraDescription = Self.describe(width: width, height: height, rotation: rotation)
            log.info("camera rotation now \(rotation * 90) degrees")
            return
        }

        cameraTask?.cancel()
        await cameraDecoder?.stop()

        let decoder = CameraDecoder()
        do {
            try await decoder.configure(
                width: width,
                height: height,
                codec: codec,
                parameterSets: parameterSets
            )
        } catch {
            log.error("camera decoder refused the configuration: \(String(describing: error), privacy: .public)")
            return
        }

        cameraWatchdog?.cancel()
        cameraWatchdog = nil
        cameraProblem = nil
        cameraDecoder = decoder
        cameraSetup = (width, height, codec, parameterSets)
        cameraRotation = rotation
        cameraDescription = Self.describe(width: width, height: height, rotation: rotation)
        log.info("camera stream \(width)×\(height), rotation \(rotation * 90) degrees")

        let frames = decoder.frames
        cameraTask = Task { [weak self] in
            var seen = 0
            for await frame in frames {
                guard let self, !Task.isCancelled else { return }
                self.cameraFrame = frame
                seen += 1
                if seen % 30 == 0 { self.log.debug("\(seen) camera frames decoded") }
                // Development hook: writes one decoded frame to disk, which is the only way
                // to check the picture actually arrives when no screen is available.
                if seen == 10 { Self.dumpIfRequested(frame) }
            }
        }
    }

    /// Says something when CAMERA_START produces no picture.
    ///
    /// The tablet cannot report it: the protocol has no way to answer a CAMERA_START, and
    /// the usual cause is a permission dialog waiting on a phone nobody is looking at. So
    /// the Mac waits, then names the likely reason rather than show a black window with no
    /// explanation.
    private func armCameraWatchdog() {
        cameraWatchdog?.cancel()
        cameraWatchdog = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard let self, !Task.isCancelled else { return }
            guard self.activeCamera != nil, self.cameraSetup == nil else { return }
            self.cameraProblem =
                "no picture, the tablet may be asking to allow its camera"
            self.log.error("no CAMERA_CONFIG 8 s after CAMERA_START")
        }
    }

    /// Size of the picture as the window shows it: a quarter turn swaps the two sides.
    private static func describe(width: Int, height: Int, rotation: Int) -> String {
        rotation % 2 == 0 ? "\(width) × \(height)" : "\(height) × \(width)"
    }

    /// Appends the Annex B bytes as received when `SIDEBUS_CAMERA_RAW` names a path. The
    /// file plays with `ffplay`, which settles whether a broken picture comes from the
    /// stream itself or from our decoding of it.
    private static func appendRawIfRequested(_ data: Data) {
        guard let path = ProcessInfo.processInfo.environment["SIDEBUS_CAMERA_RAW"], !path.isEmpty
        else { return }
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            try? handle.write(contentsOf: data)
            try? handle.close()
        } else {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }

    /// Writes a decoded frame as a PNG when `SIDEBUS_CAMERA_DUMP` names a path.
    private static func dumpIfRequested(_ frame: CapturedFrame) {
        guard let path = ProcessInfo.processInfo.environment["SIDEBUS_CAMERA_DUMP"],
            !path.isEmpty
        else { return }

        let image = CIImage(cvPixelBuffer: frame.imageBuffer)
        let context = CIContext()
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
            let data = context.pngRepresentation(
                of: image,
                format: .RGBA8,
                colorSpace: colorSpace
            )
        else { return }
        try? data.write(to: URL(fileURLWithPath: path))
        cameraLog.info("camera frame written to \(path, privacy: .public)")
    }

    // MARK: - Streaming

    /// Starts capture and pushes the stream onto the link: DISPLAY_CONFIG, then VIDEO_CONFIG
    /// on the first frame, then the VIDEO_FRAMEs.
    private func startStreaming(
        to device: PeerSession.DeviceDescription,
        session: PeerSession,
        peer: Peer
    ) async {
        await stopStreaming()

        guard ScreenCapturer.isAuthorized() else {
            ScreenCapturer.requestAuthorization()
            phase = .failed("Screen Recording permission missing")
            return
        }

        let provider: any VirtualDisplayProvider
        let displayID: CGDirectDisplayID
        let displayName: String

        if let chosen = Self.explicitlySelectedDisplay() {
            // The user named a display: respect it.
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
                displayName = "virtual display"
            } catch {
                // The API is private and can break at any macOS release. Say so, and fall back to
                // an existing display rather than fail.
                log.error(
                    """
                    virtual display unavailable \
                    (\(String(describing: error), privacy: .public)), falling back
                    """
                )
                guard let fallback = Self.firstExistingDisplay() else {
                    phase = .failed("no display to capture")
                    return
                }
                provider = ExistingDisplayProvider(targetID: fallback.id)
                displayID = fallback.id
                displayName = "\(fallback.name) (fallback)"
                usesFallbackDisplay = true
            }
        }

        let environment = ProcessInfo.processInfo.environment
        // A more careful default on Wi-Fi: fewer pixels to carry over a link we do not
        // control.
        let defaultScale = peer.kind == .wifi ? 0.75 : 1.0
        let scale = environment["SIDEBUS_CAPTURE_SCALE"].flatMap(Double.init)
            ?? UserDefaults.standard.object(forKey: DeviceManager.resolutionScaleKey) as? Double
            ?? defaultScale
        let fps = environment["SIDEBUS_FPS"].flatMap(Int.init) ?? 60

        // HEVC as soon as the tablet announces it: measured at 0.5 Mbit/s against 1.4 in
        // H.264 on the same content, decoded in hardware without a frame lost.
        //
        // Beware software decoders, the Android emulator's in particular: it returns broken
        // chroma, green and magenta blocks, where H.264 sails through. Hence
        // SIDEBUS_CODEC=h264, which forces the fallback.
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
                // The system prompt appears only once, and the permission only takes effect on
                // the next launch.
                AccessibilityPermission.request()
                log.error("Accessibility permission missing, touches will be ignored")
            }

            streamDescription = "\(displayName) → \(Int(size.width)) × \(Int(size.height))"
            phase = .streaming
            log.info(
                """
                streaming \(displayName, privacy: .public) at \
                \(Int(size.width))×\(Int(size.height))
                """
            )

            streamTask = Task { await self.pump(frames: frames, session: session) }
        } catch {
            log.error("cannot stream: \(String(describing: error), privacy: .public)")
            phase = .failed("cannot stream: \(error)")
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
                log.error("cannot send frame: \(String(describing: error), privacy: .public)")
                return
            }
        }

        // Capture stopped while the link holds, which means macOS cut it, almost always
        // because the user clicked "Stop sharing" in Control Center. That is an explicit
        // intent, aimed at this device: stop its share, otherwise reconnection restarts the
        // capture within a second and the gesture served no purpose.
        //
        // Unless the task was cancelled: another stream has already taken over, and tearing
        // down here would kill the next session.
        log.info("encoding stream ended after \(sent) frames")
        guard !Task.isCancelled, phase == .streaming else { return }
        log.info("capture cut by macOS, stopping the share")
        systemStoppedCapture?(self)
    }

    /// Called when macOS cuts the capture. `DeviceManager` uses it to drop the sharing
    /// intent, without which reconnection would restart it at once.
    @ObservationIgnored
    var systemStoppedCapture: (@MainActor (DeviceSession) -> Void)?

    /// Applies what the tablet reports: bitrate first, frame rate as a last resort.
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
            log.info("frame rate brought down to \(fps) fps")
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

    /// Display named explicitly in the settings, when it is still there.
    private static func explicitlySelectedDisplay() -> DisplayInfo? {
        guard let stored = UserDefaults.standard.object(forKey: DisplayMenuModel.selectedDisplayKey) as? Int
        else { return nil }
        let displays = (try? DisplayEnumerator.activeDisplays()) ?? []
        return displays.first { $0.id == CGDirectDisplayID(stored) }
    }

    /// Fallback when the virtual display is unavailable: a secondary display when there is
    /// one, otherwise the main display, mirrored.
    private static func firstExistingDisplay() -> DisplayInfo? {
        let displays = (try? DisplayEnumerator.activeDisplays()) ?? []
        return displays.first(where: { !$0.isMain }) ?? displays.first
    }
}
