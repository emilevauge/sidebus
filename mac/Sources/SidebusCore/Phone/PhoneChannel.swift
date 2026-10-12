import Foundation
import Network
import os

/// The Mac's end of a phone's call channel (`protocol/PROTOCOL.md` section 10): the
/// call's sound and the contacts, over USB through adb or over Wi-Fi.
///
/// Connects to the first paired phone it finds, proves it may use the calls with the token
/// the phone granted, and reconnects whenever the link drops.
public actor PhoneChannel {

    public enum State: Equatable, Sendable {
        case searching
        case connecting
        /// The phone shows a notification asking whether this Mac may carry its calls.
        case waitingForGrant(phone: String)
        case refused(phone: String)
        case ready(phone: String, over: TransportKind, helperRuns: Bool, contactsReadable: Bool)
    }

    public enum Event: Sendable {
        case state(State)
        case contacts([PhoneContact])
        /// The other party's voice, 16 kHz mono 16 bit PCM.
        case audio(Data)
        /// The phone ended the call's audio: the call is over, or the helper went away.
        case audioStopped
    }

    private let macName: String
    private let macUUID: UUID
    private let browser = BonjourBrowser(serviceType: Sidebus.callServiceType)
    private var wifiPeers: [Peer] = []
    private var usbAvailable = false
    private var session: PeerSession?
    private var onEvent: (@Sendable (Event) -> Void)?
    private var tasks: [Task<Void, Never>] = []
    private let log = Logger(subsystem: "app.sidebus", category: "phone")

    public init(macName: String, macUUID: UUID) {
        self.macName = macName
        self.macUUID = macUUID
    }

    public func start(onEvent: @escaping @Sendable (Event) -> Void) {
        self.onEvent = onEvent
        tasks.append(Task { [browser] in
            for await peers in await browser.start() {
                self.wifiPeers = peers
            }
        })
        tasks.append(Task { await self.loop() })
    }

    public func stop() async {
        tasks.forEach { $0.cancel() }
        tasks = []
        await browser.stop()
        await session?.stop(reason: "Sidebus shutting down")
    }

    /// Whether `adb forward` currently reaches the call channel on 127.0.0.1.
    public func setUSBAvailable(_ available: Bool) {
        usbAvailable = available
    }

    /// Sends on the channel, once granted. Silently dropped otherwise.
    public func send(_ message: Message) async {
        try? await session?.send(message)
    }

    // MARK: - Connection

    private func loop() async {
        while !Task.isCancelled {
            if let peer = bestPeer() {
                await run(peer)
            } else {
                emit(.state(.searching))
            }
            try? await Task.sleep(for: .seconds(2))
        }
    }

    private func bestPeer() -> Peer? {
        if usbAvailable {
            return Peer(id: "usb-call", name: "USB", kind: .usb, host: "127.0.0.1", port: Sidebus.callPort)
        }
        return wifiPeers.first
    }

    private func run(_ peer: Peer) async {
        emit(.state(.connecting))
        let transport = TransportClient(
            endpoint: peer.endpoint,
            kind: peer.kind,
            validator: KnownDeviceValidator(),
            expectedDeviceID: peer.deviceID?.uuidString
        )
        do {
            try await withTimeout(.seconds(8)) { try await transport.connect() }
        } catch {
            await transport.close()
            return
        }

        let session = PeerSession(transport: transport, macName: macName, macUUID: macUUID)
        self.session = session
        guard let events = try? await session.start() else {
            self.session = nil
            return
        }

        var phone = "the phone"
        var deviceID: String?
        for await event in events {
            switch event {
            case let .connected(device):
                phone = device.name
                deviceID = device.uuid.uuidString
                let token = await Task.detached { CallTokenStore.token(forDeviceID: device.uuid.uuidString) }.value
                try? await session.send(.callAccess(token: token ?? Data()))

            case let .received(message):
                switch message {
                case let .callGrant(status, token):
                    switch status {
                    case .granted:
                        if let deviceID {
                            await Task.detached { CallTokenStore.save(token, forDeviceID: deviceID) }.value
                        }
                        log.info("calls granted by \(phone, privacy: .public)")
                        try? await session.send(.contactsRequest)
                    case .waiting:
                        emit(.state(.waitingForGrant(phone: phone)))
                    case .refused:
                        emit(.state(.refused(phone: phone)))
                    }

                case let .callStatus(flags):
                    emit(.state(.ready(
                        phone: phone,
                        over: peer.kind,
                        helperRuns: flags & 0x01 != 0,
                        contactsReadable: flags & 0x02 != 0
                    )))

                case let .contacts(data):
                    let text = String(decoding: data, as: UTF8.self)
                    emit(.contacts(ContactBook.parse(lines: text)))

                case let .callAudio(pcm):
                    emit(.audio(pcm))

                case .callStop:
                    emit(.audioStopped)

                default:
                    break
                }

            case .roundTrip:
                break

            case let .closed(reason):
                log.info("call channel closed: \(reason, privacy: .public)")
            }
        }
        self.session = nil
        emit(.audioStopped)
    }

    private func emit(_ event: Event) {
        onEvent?(event)
    }
}
