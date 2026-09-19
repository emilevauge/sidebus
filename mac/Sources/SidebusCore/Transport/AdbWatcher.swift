import Foundation
import Network

/// USB discovery: follows the devices the adb server sees, sets up the port tunnel, and
/// starts the application on the tablet when needed.
///
/// The adb server's `host:track-devices` stream is persistent: the server pushes a fresh
/// list on every plug and unplug, with no polling on our side. Same approach as scrcpy
/// (Apache 2.0, see mac/THIRD_PARTY.md), reimplemented here on `NWConnection`.
public actor AdbWatcher: PeerDiscovery {

    public struct Device: Sendable, Hashable {
        public let serial: String
        /// `device`, `unauthorized`, `offline`, ...
        public let state: String

        public var isUsable: Bool { state == "device" }
    }

    public enum AdbError: Error, CustomStringConvertible, Sendable {
        case adbNotFound
        case commandFailed(String, Int32, String)

        public var description: String {
            switch self {
            case .adbNotFound:
                return """
                    adb introuvable. Installer les platform-tools Android, ou \
                    utiliser le Wi-Fi.
                    """
            case let .commandFailed(command, status, output):
                return "adb \(command) failed (code \(status)): \(output)"
            }
        }
    }

    /// Locations searched, in order. PATH first, as for any tool.
    private static let searchPaths = [
        "/opt/homebrew/bin/adb",
        "/usr/local/bin/adb",
        NSHomeDirectory() + "/Library/Android/sdk/platform-tools/adb",
    ]

    public static func locateAdb() -> String? {
        if let fromPath = which("adb") { return fromPath }
        return searchPaths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static func which(_ tool: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["which", tool]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let output = String(
            decoding: pipe.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        return output.isEmpty ? nil : output
    }

    public let port: UInt16

    /// Marketing name of each device, learned through `getprop`. Without it the list shows
    /// nothing but unreadable adb serials.
    private var models: [String: String] = [:]
    private var connection: NWConnection?
    private var continuation: AsyncStream<[Peer]>.Continuation?
    private let queue = DispatchQueue(label: "app.sidebus.adb")

    public init(port: UInt16 = Sidebus.port) {
        self.port = port
    }

    /// Stream of tablets seen on USB. Each element is the full list, not a delta.
    public func start() async -> AsyncStream<[Peer]> {
        await stop()

        let (stream, continuation) = AsyncStream<[Peer]>.makeStream(bufferingPolicy: .bufferingNewest(4))
        self.continuation = continuation

        Task { await trackDevices() }
        return stream
    }

    public func stop() async {
        connection?.cancel()
        connection = nil
        continuation?.finish()
        continuation = nil
    }

    // MARK: - Flux track-devices

    private func trackDevices() async {
        guard let adb = Self.locateAdb() else {
            continuation?.finish()
            return
        }

        // The adb server may not be running, and the stream requires it to be.
        _ = try? await run(adb, ["start-server"])

        let connection = NWConnection(
            host: "127.0.0.1",
            port: 5037,
            using: .tcp
        )
        self.connection = connection

        do {
            try await withCheckedThrowingContinuation { (resume: CheckedContinuation<Void, Error>) in
                let resumed = AdbResumed()
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        if resumed.claim() { resume.resume() }
                    case let .failed(error):
                        if resumed.claim() {
                            resume.resume(throwing: TransportError.connectionFailed("\(error)"))
                        }
                    case .cancelled:
                        if resumed.claim() { resume.resume(throwing: TransportError.closed) }
                    default:
                        break
                    }
                }
                connection.start(queue: queue)
            }

            // adb protocol request: length on 4 hexadecimal characters, then the service
            // being asked for.
            let request = "host:track-devices"
            let framed = String(format: "%04x", request.count) + request
            try await send(Data(framed.utf8), on: connection)

            let status = try await receive(exactly: 4, on: connection)
            guard String(decoding: status, as: UTF8.self) == "OKAY" else {
                continuation?.finish()
                return
            }

            while true {
                let lengthBytes = try await receive(exactly: 4, on: connection)
                guard let length = Int(String(decoding: lengthBytes, as: UTF8.self), radix: 16) else {
                    break
                }
                let body = length > 0 ? try await receive(exactly: length, on: connection) : Data()
                let devices = Self.parseDevices(String(decoding: body, as: UTF8.self))
                let usable = devices.filter(\.isUsable)
                continuation?.yield(usable.map(peer(for:)))
                // In the background: the list goes out right away, the names follow.
                Task { await self.learnModels(of: usable) }
            }
        } catch {
            // adb server lost: the stream ends, the caller decides whether to restart.
        }

        continuation?.finish()
    }

    private func peer(for device: Device) -> Peer {
        Peer(
            id: device.serial,
            // The model when already asked for, otherwise the serial in the meantime. The
            // exact name, the one the user gave the tablet, arrives later
            // dans DEVICE_INFO.
            name: models[device.serial] ?? device.serial,
            kind: .usb,
            host: "127.0.0.1",
            port: port
        )
    }

    /// Asks for the model of devices not known yet, then republishes the list.
    ///
    /// One `getprop` per device, once. It is a few milliseconds of round trip, but doing it
    /// on every `track-devices` announcement would be waste.
    private func learnModels(of devices: [Device]) async {
        guard let adb = Self.locateAdb() else { return }
        var learned = false

        for device in devices where models[device.serial] == nil {
            // Marketing name first: `ro.product.model` gives the factory code, something like
            // 24129PN74G, where marketname gives "Xiaomi 15". These keys vary from one
            // manufacturer to the next, hence the list. One shell call tries them all, and
            // the first non empty line wins.
            guard let output = try? await run(
                adb,
                [
                    "-s", device.serial, "shell",
                    """
                    getprop ro.product.marketname; \
                    getprop ro.vendor.product.marketname; \
                    getprop ro.config.marketing_name; \
                    getprop ro.product.model
                    """,
                ]
            ) else { continue }

            guard let name = output
                .split(separator: "\n")
                .map({ $0.trimmingCharacters(in: .whitespaces) })
                .first(where: { !$0.isEmpty })
            else { continue }
            models[device.serial] = name
            learned = true
        }

        guard learned else { return }
        continuation?.yield(devices.filter(\.isUsable).map(peer(for:)))
    }

    /// Parses the `track-devices` payload: one line per device, `<serial>\t<state>`.
    static func parseDevices(_ text: String) -> [Device] {
        text.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: "\t", maxSplits: 1)
            guard fields.count == 2 else { return nil }
            return Device(
                serial: String(fields[0]).trimmingCharacters(in: .whitespaces),
                state: String(fields[1]).trimmingCharacters(in: .whitespaces)
            )
        }
    }

    // MARK: - adb commands

    /// `adb forward` maps a local Mac port onto a port the device listens on. That is the
    /// direction we need, the tablet being the server.
    public func forward(serial: String, localPort: UInt16, devicePort: UInt16) async throws {
        guard let adb = Self.locateAdb() else { throw AdbError.adbNotFound }
        _ = try await run(adb, ["-s", serial, "forward", "tcp:\(localPort)", "tcp:\(devicePort)"])
    }

    public func removeForward(localPort: UInt16) async {
        guard let adb = Self.locateAdb() else { return }
        _ = try? await run(adb, ["forward", "--remove", "tcp:\(localPort)"])
    }

    /// Starts the application on the tablet. Useful when the connection fails: usually the
    /// app is simply not in the foreground.
    public func launchApp(serial: String) async throws {
        guard let adb = Self.locateAdb() else { throw AdbError.adbNotFound }
        _ = try await run(
            adb,
            ["-s", serial, "shell", "am", "start", "-n", "app.sidebus/.MainActivity"]
        )
    }

    @discardableResult
    private func run(_ executable: String, _ arguments: [String]) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw AdbError.commandFailed(
                arguments.joined(separator: " "),
                process.terminationStatus,
                output.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        return output
    }

    // MARK: - adb socket input and output

    private func send(_ data: Data, on connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (resume: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    resume.resume(throwing: TransportError.connectionFailed("\(error)"))
                } else {
                    resume.resume()
                }
            })
        }
    }

    private func receive(exactly count: Int, on connection: NWConnection) async throws -> Data {
        try await withCheckedThrowingContinuation { (resume: CheckedContinuation<Data, Error>) in
            connection.receive(minimumIncompleteLength: count, maximumLength: count) {
                data, _, isComplete, error in
                if let error {
                    resume.resume(throwing: TransportError.connectionFailed("\(error)"))
                } else if let data, data.count == count {
                    resume.resume(returning: data)
                } else if isComplete {
                    resume.resume(throwing: TransportError.closed)
                } else {
                    resume.resume(throwing: TransportError.closed)
                }
            }
        }
    }
}

private final class AdbResumed: @unchecked Sendable {
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
