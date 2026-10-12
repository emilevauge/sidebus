import Foundation
import Network
import os

/// Wi-Fi discovery: the tablet advertises itself, the Mac finds it.
///
/// Connecting to a result goes straight through its `NWEndpoint`, with no address resolved
/// by hand: `NWConnection` handles that, including when the address changes.
///
/// A trap worth knowing: since macOS 15, without `NSLocalNetworkUsageDescription` and
/// `NSBonjourServices` in the Info.plist, and without a stable signature, the browser
/// returns nothing at all **and raises no error**.
public actor BonjourBrowser: PeerDiscovery {
    private var browser: NWBrowser?
    private var continuation: AsyncStream<[Peer]>.Continuation?
    private let queue = DispatchQueue(label: "app.sidebus.bonjour")

    private let serviceType: String

    public init(serviceType: String = Sidebus.serviceType) {
        self.serviceType = serviceType
    }

    public func start() async -> AsyncStream<[Peer]> {
        await stop()

        let (stream, continuation) = AsyncStream<[Peer]>.makeStream(
            bufferingPolicy: .bufferingNewest(4)
        )
        self.continuation = continuation

        let parameters = NWParameters()
        parameters.includePeerToPeer = false

        let browser = NWBrowser(
            for: .bonjourWithTXTRecord(type: serviceType, domain: nil),
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
                browserLog.error("browser failed: \(String(describing: error), privacy: .public)")
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

    /// Builds a tablet from a result and its TXT records. See `protocol/PROTOCOL.md`
    /// section 8 for the keys.
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
