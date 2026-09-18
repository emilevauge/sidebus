import Foundation
import Network
import os

/// Découverte Wi-Fi : la tablette s'annonce, le Mac la trouve.
///
/// Se connecter à un résultat se fait directement avec son `NWEndpoint`, sans résoudre
/// l'adresse à la main : `NWConnection` s'en charge, y compris quand l'adresse change.
///
/// Piège à connaître : depuis macOS 15, sans `NSLocalNetworkUsageDescription` ni
/// `NSBonjourServices` dans l'Info.plist, et sans signature stable, le navigateur ne
/// renvoie jamais rien **et ne produit aucune erreur**.
public actor BonjourBrowser: PeerDiscovery {
    private var browser: NWBrowser?
    private var continuation: AsyncStream<[Peer]>.Continuation?
    private let queue = DispatchQueue(label: "app.sidebus.bonjour")

    public init() {}

    public func start() async -> AsyncStream<[Peer]> {
        await stop()

        let (stream, continuation) = AsyncStream<[Peer]>.makeStream(
            bufferingPolicy: .bufferingNewest(4)
        )
        self.continuation = continuation

        let parameters = NWParameters()
        parameters.includePeerToPeer = false

        let browser = NWBrowser(
            for: .bonjourWithTXTRecord(type: Sidebus.serviceType, domain: nil),
            using: parameters
        )
        self.browser = browser

        browser.browseResultsChangedHandler = { results, _ in
            let peers = results.compactMap(Self.peer(from:))
            continuation.yield(peers)
        }

        browser.stateUpdateHandler = { state in
            switch state {
            case let .failed(error):
                browserLog.error("navigateur en échec : \(String(describing: error), privacy: .public)")
                continuation.finish()
            case .cancelled:
                continuation.finish()
            default:
                break
            }
        }

        browser.start(queue: queue)
        return stream
    }

    public func stop() async {
        browser?.cancel()
        browser = nil
        continuation?.finish()
        continuation = nil
    }

    /// Construit une tablette à partir d'un résultat et de ses enregistrements TXT.
    /// Voir `protocol/PROTOCOL.md` section 8 pour les clés.
    static func peer(from result: NWBrowser.Result) -> Peer? {
        guard case let .service(name, _, _, _) = result.endpoint else { return nil }

        var deviceID: UUID?
        if case let .bonjour(record) = result.metadata, let identifier = record["id"] {
            deviceID = UUID(uuidString: identifier)
        }

        return Peer(
            id: name,
            name: name,
            kind: .wifi,
            endpoint: result.endpoint,
            deviceID: deviceID
        )
    }
}

let browserLog = Logger(subsystem: "app.sidebus", category: "bonjour")
