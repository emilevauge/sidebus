import Foundation
import Network

public enum TransportKind: String, Sendable, Hashable {
    case usb
    case wifi
}

public enum TransportError: Error, CustomStringConvertible, Sendable {
    case connectionFailed(String)
    case closed
    case handshakeFailed(String)
    case timedOut

    public var description: String {
        switch self {
        case let .connectionFailed(reason): return "cannot connect: \(reason)"
        case .closed: return "connection closed"
        case let .handshakeFailed(reason): return "handshake failed: \(reason)"
        case .timedOut: return "timed out"
        }
    }
}

/// An established link to the tablet. No business code should know whether it runs over
/// USB or Wi-Fi: that is the whole point of this abstraction.
public protocol Transport: Sendable {
    var kind: TransportKind { get }

    /// Messages received, in order. The stream ends when the link closes.
    var messages: AsyncStream<Message> { get }

    func send(_ message: Message) async throws
    func close() async
}

/// A tablet spotted, by one means or another.
public struct Peer: Sendable, Hashable, Identifiable {
    /// Identifier of the discovery channel: adb serial on USB, service name on Wi-Fi. Two
    /// transports to the same tablet therefore carry two different `id` values, and
    /// `deviceID` is what brings them together.
    public let id: String
    public let name: String
    public let kind: TransportKind
    public let endpoint: NWEndpoint

    /// Persistent identifier of the tablet, when known before connecting. It comes from
    /// the `id` TXT record on Wi-Fi. On USB it only arrives with DEVICE_INFO.
    public let deviceID: UUID?

    public init(
        id: String,
        name: String,
        kind: TransportKind,
        endpoint: NWEndpoint,
        deviceID: UUID? = nil
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.endpoint = endpoint
        self.deviceID = deviceID
    }

    public init(
        id: String,
        name: String,
        kind: TransportKind,
        host: String,
        port: UInt16,
        deviceID: UUID? = nil
    ) {
        self.init(
            id: id,
            name: name,
            kind: kind,
            endpoint: .hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!),
            deviceID: deviceID
        )
    }
}

/// A source of tablets. `AdbWatcher` in phase 3, `BonjourBrowser` in phase 6.
public protocol PeerDiscovery: Sendable {
    func start() async -> AsyncStream<[Peer]>
    func stop() async
}
