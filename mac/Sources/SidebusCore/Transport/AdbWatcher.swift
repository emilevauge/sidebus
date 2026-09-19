import Foundation
import Network

/// Découverte USB : suit les appareils vus par le serveur adb, met en place le tunnel de
/// port, et lance l'application sur la tablette si besoin.
///
/// Le flux `host:track-devices` du serveur adb est persistant : le serveur pousse une
/// nouvelle liste à chaque branchement ou débranchement, sans qu'on ait à interroger.
/// C'est la même approche que scrcpy (Apache 2.0, voir PLAN.md section 5), réimplémentée
/// ici sur `NWConnection`.
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
                return "adb \(command) a échoué (code \(status)) : \(output)"
            }
        }
    }

    /// Emplacements fouillés, dans l'ordre. Le PATH d'abord, comme pour tout outil.
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

    /// Nom commercial de chaque appareil, appris par `getprop`. Sans lui la liste n'affiche
    /// que des numéros de série adb, illisibles.
    private var models: [String: String] = [:]
    private var connection: NWConnection?
    private var continuation: AsyncStream<[Peer]>.Continuation?
    private let queue = DispatchQueue(label: "app.sidebus.adb")

    public init(port: UInt16 = Sidebus.port) {
        self.port = port
    }

    /// Flux des tablettes vues en USB. Chaque élément est la liste complète, pas un delta.
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

        // Le serveur adb n'est pas forcément démarré, et le flux exige qu'il le soit.
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

            // Requête du protocole adb : longueur sur 4 caractères hexadécimaux, puis
            // le service demandé.
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
                // En tâche de fond : la liste sort tout de suite, les noms arrivent après.
                Task { await self.learnModels(of: usable) }
            }
        } catch {
            // Perte du serveur adb : le flux se termine, l'appelant décidera de relancer.
        }

        continuation?.finish()
    }

    private func peer(for device: Device) -> Peer {
        Peer(
            id: device.serial,
            // Le modèle si on l'a déjà demandé, sinon le numéro de série en attendant. Le
            // nom exact, celui que l'utilisateur a donné à sa tablette, arrive plus tard
            // dans DEVICE_INFO.
            name: models[device.serial] ?? device.serial,
            kind: .usb,
            host: "127.0.0.1",
            port: port
        )
    }

    /// Demande le modèle des appareils qu'on ne connaît pas encore, puis republie la liste.
    ///
    /// Un `getprop` par appareil, une seule fois : c'est un aller retour de quelques
    /// millisecondes, mais le faire à chaque annonce de `track-devices` serait du gaspillage.
    private func learnModels(of devices: [Device]) async {
        guard let adb = Self.locateAdb() else { return }
        var learned = false

        for device in devices where models[device.serial] == nil {
            // Le nom commercial d'abord : `ro.product.model` donne le code usine, du genre
            // 24129PN74G, là où marketname donne « Xiaomi 15 ». Ces clés varient d'un
            // constructeur à l'autre, d'où la liste. Un seul appel shell pour les essayer
            // toutes, et la première ligne non vide gagne.
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

    /// Analyse la charge utile de `track-devices` : une ligne par appareil,
    /// `<série>\t<état>`.
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

    // MARK: - Commandes adb

    /// `adb forward` mappe un port local du Mac vers un port en écoute sur l'appareil.
    /// C'est la direction dont on a besoin, la tablette étant le serveur.
    public func forward(serial: String, localPort: UInt16, devicePort: UInt16) async throws {
        guard let adb = Self.locateAdb() else { throw AdbError.adbNotFound }
        _ = try await run(adb, ["-s", serial, "forward", "tcp:\(localPort)", "tcp:\(devicePort)"])
    }

    public func removeForward(localPort: UInt16) async {
        guard let adb = Self.locateAdb() else { return }
        _ = try? await run(adb, ["forward", "--remove", "tcp:\(localPort)"])
    }

    /// Lance l'application sur la tablette. Utile quand la connexion échoue : c'est en
    /// général qu'elle n'est pas au premier plan.
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

    // MARK: - Entrées sorties du socket adb

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
