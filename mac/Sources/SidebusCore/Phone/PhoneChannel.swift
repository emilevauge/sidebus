import Foundation
import Network
import os

/// The Mac's end of a phone's call channel (`protocol/PROTOCOL.md` section 10): the
/// call's sound and the contacts, over USB through adb or over Wi-Fi.
///
/// Connects only when needed, since a live link keeps the phone's Wi-Fi awake: for the
/// length of a call, which Bluetooth announces, and every 15 minutes for a short check of
/// the phone's state and contacts. Each time it proves it may use the calls with the token
/// the phone granted.
public actor PhoneChannel {

    public enum State: Equatable, Sendable {
        case searching
        case connecting
        /// The phone shows a notification asking whether this Mac may carry its calls.
        case waitingForGrant(phone: String)
        case refused(phone: String)
        /// Connected: the call's sound can flow.
        case ready(phone: String, over: TransportKind, helperRuns: Bool, contactsReadable: Bool)
        /// Not connected, on purpose, between calls: what the last check found.
        case resting(phone: String, over: TransportKind, helperRuns: Bool, contactsReadable: Bool)
    }

    /// Between two checks of the phone, outside calls.
    public static let checkInterval = Duration.seconds(15 * 60)

    public enum Event: Sendable {
        case state(State)
        case contacts([PhoneContact])
        /// The other party's voice, 16 kHz mono 16 bit PCM.
        case audio(Data)
        /// The phone ended the call's audio: the call is over, or the helper went away.
        case audioStopped
        /// The phone's persistent identifier, the one its screen pairing knows it by.
        case device(UUID)
        /// Who rings, as the phone's call screen shows it: a contact, a business, a spam
        /// warning.
        case caller(title: String, text: String)
        /// Whether the phone may read its dialer's notification, for the caller names.
        case callerNamesReadable(Bool)
    }

    private let macName: String
    private let macUUID: UUID
    private let browser = BonjourBrowser(serviceType: Sidebus.callServiceType)
    private var wifiPeers: [Peer] = []
    private var usbAvailable = false
    private var inCall = false
    private var checkDue = true
    private var lastStatus: (phone: String, flags: UInt8)?
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

    /// Whether `adb forward` currently reaches the call channel on 127.0.0.1. A plug also
    /// calls for a check: the helper may just have started.
    public func setUSBAvailable(_ available: Bool) {
        usbAvailable = available
        if available { checkDue = true }
    }

    /// Holds the link open while a call is placed, rings or goes on.
    public func setInCall(_ inCall: Bool) {
        self.inCall = inCall
    }

    /// Asks for a check now, contacts included.
    public func checkSoon() {
        checkDue = true
    }

    /// Sends on the channel, once granted. Silently dropped otherwise.
    public func send(_ message: Message) async {
        try? await session?.send(message)
    }

    // MARK: - Connection

    private func loop() async {
        var nextCheck = ContinuousClock.now
        while !Task.isCancelled {
            if ContinuousClock.now >= nextCheck { checkDue = true }
            if inCall || checkDue {
                if let peer = bestPeer() {
                    let checked = await run(peer)
                    if checked {
                        checkDue = false
                        nextCheck = .now + Self.checkInterval
                    }
                } else if lastStatus == nil {
                    emit(.state(.searching))
                }
            }
            try? await Task.sleep(for: .seconds(1))
        }
    }

    private func bestPeer() -> Peer? {
        if usbAvailable {
            return Peer(id: "usb-call", name: "USB", kind: .usb, host: "127.0.0.1", port: Sidebus.callPort)
        }
        return wifiPeers.first
    }

    /// One connection, held while a call goes on, or until the check is through. Returns
    /// true once the phone's status and contacts came.
    private func run(_ peer: Peer) async -> Bool {
        // Once the phone's state is known, it stands while connecting again: a passing
        // "connecting" made the phone's row and its status come and go in the panel.
        if lastStatus == nil { emit(.state(.connecting)) }
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
            return false
        }

        let session = PeerSession(transport: transport, macName: macName, macUUID: macUUID)
        self.session = session
        guard let events = try? await session.start() else {
            self.session = nil
            return false
        }

        // Lets the check end once its answers are in, the call aside.
        let closer = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                if self.checkComplete && !self.inCall {
                    await session.stop(reason: "check done")
                    return
                }
            }
        }
        defer { closer.cancel() }

        checkComplete = false
        var gotStatus = false
        var gotContacts = false
        var phone = "the phone"
        var deviceID: String?
        for await event in events {
            switch event {
            case let .connected(device):
                phone = device.name
                deviceID = device.uuid.uuidString
                emit(.device(device.uuid))
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
                        checkComplete = true
                    }

                case let .callStatus(flags):
                    lastStatus = (phone, flags)
                    gotStatus = true
                    checkComplete = gotContacts || flags & 0x02 == 0
                    emit(.state(.ready(
                        phone: phone,
                        over: peer.kind,
                        helperRuns: flags & 0x01 != 0,
                        contactsReadable: flags & 0x02 != 0
                    )))
                    emit(.callerNamesReadable(flags & 0x04 != 0))

                case let .contacts(data):
                    let text = String(decoding: data, as: UTF8.self)
                    emit(.contacts(ContactBook.parse(lines: text)))
                    gotContacts = true
                    checkComplete = gotStatus

                case let .callAudio(pcm):
                    emit(.audio(pcm))

                case let .callerID(data):
                    let lines = String(decoding: data, as: UTF8.self).split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
                    emit(.caller(title: lines.first.map(String.init) ?? "", text: lines.count > 1 ? String(lines[1]) : ""))

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
        if let lastStatus {
            emit(.state(.resting(
                phone: lastStatus.phone,
                over: peer.kind,
                helperRuns: lastStatus.flags & 0x01 != 0,
                contactsReadable: lastStatus.flags & 0x02 != 0
            )))
        }
        return gotStatus
    }

    private var checkComplete = false

    private func emit(_ event: Event) {
        onEvent?(event)
    }
}
