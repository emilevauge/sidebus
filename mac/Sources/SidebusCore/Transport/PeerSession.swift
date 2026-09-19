import Foundation

/// Drives one connection: handshake, then PING/PONG until it closes.
///
/// C'est le Mac qui envoie HELLO, puisque c'est lui qui se connecte. Voir
/// `protocol/PROTOCOL.md`, section 6.
public actor PeerSession {

    public enum Event: Sendable {
        case connected(DeviceDescription)
        case roundTrip(milliseconds: Double)
        case received(Message)
        case closed(reason: String)
    }

    public struct DeviceDescription: Sendable, Hashable {
        public let name: String
        /// Persistent device identifier, the key to arbitrating between transports.
        public let uuid: UUID
        public let width: UInt16
        public let height: UInt16
        public let density: UInt16
        public let codecs: UInt8

        public var supportsHEVC: Bool { codecs & Codec.hevc.rawValue != 0 }
    }

    /// Interval between two PINGs, and the delay after which the peer counts as lost.
    public static let pingInterval = Duration.seconds(1)
    public static let pingTimeout = Duration.seconds(5)

    private let transport: any Transport
    private let macName: String
    private let macUUID: UUID

    private var continuation: AsyncStream<Event>.Continuation?
    private var pingTask: Task<Void, Never>?
    private var readTask: Task<Void, Never>?
    private var lastPongUptime: UInt64 = PeerSession.uptimeMicroseconds()

    public init(transport: any Transport, macName: String, macUUID: UUID) {
        self.transport = transport
        self.macName = macName
        self.macUUID = macUUID
    }

    public func start() async throws -> AsyncStream<Event> {
        let (stream, continuation) = AsyncStream<Event>.makeStream(bufferingPolicy: .bufferingNewest(32))
        self.continuation = continuation

        try await transport.send(
            .hello(version: Sidebus.protocolVersion, name: macName, uuid: macUUID)
        )

        lastPongUptime = Self.uptimeMicroseconds()
        readTask = Task { await readLoop() }
        pingTask = Task { await pingLoop() }

        return stream
    }

    /// Sends a message on the session's link.
    public func send(_ message: Message) async throws {
        try await transport.send(message)
    }

    public func stop(reason: String = "stop requested") async {
        pingTask?.cancel()
        readTask?.cancel()
        pingTask = nil
        readTask = nil
        await transport.close()
        continuation?.yield(.closed(reason: reason))
        continuation?.finish()
        continuation = nil
    }

    private func readLoop() async {
        for await message in transport.messages {
            switch message {
            case let .deviceInfo(width, height, density, codecs, name, uuid):
                continuation?.yield(
                    .connected(
                        DeviceDescription(
                            name: name,
                            uuid: uuid,
                            width: width,
                            height: height,
                            density: density,
                            codecs: codecs
                        )
                    )
                )

            case let .pong(timestamp):
                lastPongUptime = Self.uptimeMicroseconds()
                let elapsed = Double(lastPongUptime &- timestamp) / 1000
                continuation?.yield(.roundTrip(milliseconds: elapsed))

            case let .ping(timestamp):
                try? await transport.send(.pong(timestamp: timestamp))

            case let .bye(reason):
                await stop(reason: "BYE received, reason \(reason.rawValue)")
                return

            default:
                continuation?.yield(.received(message))
            }
        }

        // The stream ends when the link falls.
        await stop(reason: "link closed")
    }

    private func pingLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: Self.pingInterval)
            guard !Task.isCancelled else { return }

            let silence = Self.uptimeMicroseconds() &- lastPongUptime
            if silence > UInt64(Self.pingTimeout.components.seconds) * 1_000_000 {
                await stop(reason: "peer silent for 5 s")
                return
            }

            do {
                try await transport.send(.ping(timestamp: Self.uptimeMicroseconds()))
            } catch {
                await stop(reason: "cannot send: \(error)")
                return
            }
        }
    }

    /// Monotonic clock, in microseconds. Never goes back and ignores system time changes.
    public static func uptimeMicroseconds() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds / 1000
    }
}
