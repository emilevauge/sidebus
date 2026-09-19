import Foundation
import Network
import XCTest

@testable import SidebusCore

/// Garde qu'une continuation n'est reprise qu'une fois.
private final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
}

/// A fake tablet: listens locally, answers DEVICE_INFO to HELLO and PONG to PING. Same
/// role as the Android app, cut down to the strict minimum.
private final class FakeTablet: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "test.tablette")
    private var connection: NWConnection?
    private var decoder = MessageDecoder()
    private let lock = NSLock()

    private(set) var receivedHello: Message?

    init() throws {
        let options = NWProtocolTCP.Options()
        options.noDelay = true
        listener = try NWListener(using: NWParameters(tls: nil, tcp: options), on: .any)
    }

    func start() async throws -> UInt16 {
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            self.connection = connection
            connection.start(queue: self.queue)
            self.receive(on: connection)
        }

        let once = OnceFlag()
        return try await withCheckedThrowingContinuation { resume in
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    if once.claim() { resume.resume(returning: self?.listener.port?.rawValue ?? 0) }
                case let .failed(error):
                    if once.claim() { resume.resume(throwing: error) }
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        connection?.cancel()
        listener.cancel()
    }

    private func receive(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self, error == nil, !isComplete else { return }
            if let data, !data.isEmpty {
                self.lock.lock()
                self.decoder.append(data)
                var messages: [Message] = []
                while let message = try? self.decoder.next() {
                    messages.append(message)
                }
                self.lock.unlock()

                for message in messages {
                    self.respond(to: message, on: connection)
                }
            }
            self.receive(on: connection)
        }
    }

    private func respond(to message: Message, on connection: NWConnection) {
        switch message {
        case .hello:
            lock.lock()
            receivedHello = message
            lock.unlock()
            send(
                .deviceInfo(
                    width: 2560,
                    height: 1600,
                    density: 320,
                    codecs: 0x03,
                    name: "Tablette de test",
                    uuid: UUID(uuidString: "7C9E6679-7425-40DE-944B-E07FC1F90AE7")!
                ),
                on: connection
            )
        case let .ping(timestamp):
            send(.pong(timestamp: timestamp), on: connection)
        default:
            break
        }
    }

    private func send(_ message: Message, on connection: NWConnection) {
        connection.send(content: MessageCodec.encode(message), completion: .idempotent)
    }
}

final class PeerSessionTests: XCTestCase {

    func testHandshakeThenPing() async throws {
        let tablet = try FakeTablet()
        let port = try await tablet.start()
        defer { tablet.stop() }

        let client = TransportClient(host: "127.0.0.1", port: port, kind: .usb)
        try await client.connect()

        let session = PeerSession(transport: client, macName: "Mac de test", macUUID: UUID())
        let events = try await session.start()

        var device: PeerSession.DeviceDescription?
        var roundTrip: Double?

        for await event in events {
            switch event {
            case let .connected(description):
                device = description
            case let .roundTrip(milliseconds):
                roundTrip = milliseconds
            default:
                break
            }
            if device != nil, roundTrip != nil { break }
        }

        await session.stop()

        let described = try XCTUnwrap(device)
        XCTAssertEqual(described.name, "Tablette de test")
        XCTAssertEqual(described.width, 2560)
        XCTAssertEqual(described.height, 1600)
        XCTAssertTrue(described.supportsHEVC)

        let measured = try XCTUnwrap(roundTrip)
        XCTAssertGreaterThan(measured, 0)
        XCTAssertLessThan(measured, 1000, "aller retour local anormalement long")

        // Le Mac est bien celui qui ouvre le dialogue.
        guard case let .hello(version, name, _)? = tablet.receivedHello else {
            return XCTFail("HELLO not received by the tablet")
        }
        XCTAssertEqual(version, Sidebus.protocolVersion)
        XCTAssertEqual(name, "Mac de test")
    }

    func testParsesTrackDevicesOutput() {
        let devices = AdbWatcher.parseDevices(
            "R5CT80ABCDE\tdevice\nemulator-5554\tdevice\n0123456789\tunauthorized\n"
        )
        XCTAssertEqual(devices.count, 3)
        XCTAssertEqual(devices[0].serial, "R5CT80ABCDE")
        XCTAssertTrue(devices[0].isUsable)
        XCTAssertEqual(devices[2].state, "unauthorized")
        XCTAssertFalse(devices[2].isUsable)
        XCTAssertTrue(AdbWatcher.parseDevices("").isEmpty)
    }
}
