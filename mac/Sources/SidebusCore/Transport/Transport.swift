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
        case let .connectionFailed(reason): return "connexion impossible : \(reason)"
        case .closed: return "connexion fermée"
        case let .handshakeFailed(reason): return "handshake échoué : \(reason)"
        case .timedOut: return "délai dépassé"
        }
    }
}

/// Un lien établi avec la tablette. Aucun code métier ne doit savoir s'il tourne en USB
/// ou en Wi-Fi : c'est toute la raison d'être de cette abstraction.
public protocol Transport: Sendable {
    var kind: TransportKind { get }

    /// Messages reçus, dans l'ordre. Le flux se termine à la fermeture du lien.
    var messages: AsyncStream<Message> { get }

    func send(_ message: Message) async throws
    func close() async
}

/// Une tablette repérée, par un moyen ou un autre.
public struct Peer: Sendable, Hashable, Identifiable {
    /// Identifiant du moyen de découverte : numéro de série adb en USB, nom du service en
    /// Wi-Fi. Deux transports vers la même tablette ont donc deux `id` différents, c'est
    /// `deviceID` qui les réunit.
    public let id: String
    public let name: String
    public let kind: TransportKind
    public let endpoint: NWEndpoint

    /// Identifiant persistant de la tablette, quand il est connu avant de se connecter.
    /// Il vient du TXT `id` en Wi-Fi. En USB il n'arrive qu'avec DEVICE_INFO.
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

/// Source de tablettes. `AdbWatcher` en phase 3, `BonjourBrowser` en phase 6.
public protocol PeerDiscovery: Sendable {
    func start() async -> AsyncStream<[Peer]>
    func stop() async
}
