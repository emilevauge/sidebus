import Foundation
import os

/// Everything the phone side of calls needs over adb: finding the phone among the
/// devices, reading its contacts through the Sidebus app, and keeping the call bridge
/// (android/callbridge) running on it, with the port forward that reaches it.
public actor PhoneBridgeHost {

    public enum Status: Equatable, Sendable {
        /// No phone on adb: plugged out, or USB debugging off.
        case noPhone
        case starting
        /// The bridge runs on the phone, calls can carry audio.
        case ready
        case failed(String)
    }

    /// Mac port forwarded to the bridge's socket on the phone.
    public static let port: UInt16 = 27184
    private static let remoteDex = "/data/local/tmp/sidebus-callbridge.dex"

    private let dex: URL
    private var serial: String?
    private var process: Process?
    private var statusHandler: (@Sendable (Status) -> Void)?
    private var watch: Task<Void, Never>?
    private let log = Logger(subsystem: "app.sidebus", category: "phone")

    /// `dex` is CallBridge built by android/callbridge/build.sh, shipped in the app.
    public init(dex: URL) {
        self.dex = dex
    }

    /// Looks for a phone every few seconds, and keeps the bridge running on it.
    public func start(onStatus: @escaping @Sendable (Status) -> Void) {
        statusHandler = onStatus
        watch?.cancel()
        watch = Task { [weak self] in
            while !Task.isCancelled {
                await self?.check()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    public func stop() async {
        watch?.cancel()
        watch = nil
        await stopBridge()
    }

    /// The phone's contacts. Nil when the Sidebus app lacks the permission: it then
    /// asks for it on the phone, and a later call returns the list.
    public func contacts() async throws -> [PhoneContact]? {
        guard let serial else { return [] }
        let output = try await adb(["-s", serial, "shell", "content", "query", "--uri", "content://app.sidebus.contacts/phones"])
        if let contacts = ContactBook.parse(output) { return contacts }
        _ = try? await adb(["-s", serial, "shell", "am", "start", "-n", "app.sidebus/.phone.ContactsAccessActivity"])
        return nil
    }

    // MARK: - Bridge

    private func check() async {
        if let process, process.isRunning { return }
        guard let phone = await findPhone() else {
            if serial != nil || process == nil { report(.noPhone) }
            serial = nil
            process = nil
            return
        }
        serial = phone
        report(.starting)
        do {
            try await startBridge(on: phone)
        } catch {
            log.error("call bridge: \(String(describing: error), privacy: .public)")
            report(.failed(String(describing: error)))
        }
    }

    /// The first device with a SIM card. A tablet plugged for screen sharing has none.
    private func findPhone() async -> String? {
        guard let output = try? await adb(["devices"]) else { return nil }
        let serials = output.split(separator: "\n").dropFirst().compactMap { line -> String? in
            let fields = line.split(separator: "\t")
            guard fields.count == 2, fields[1] == "device", !fields[0].hasPrefix("emulator-") else { return nil }
            return String(fields[0])
        }
        for serial in serials {
            let sim = (try? await adb(["-s", serial, "shell", "getprop", "gsm.sim.state"])) ?? ""
            if sim.contains("LOADED") || sim.contains("READY") { return serial }
        }
        return nil
    }

    private func startBridge(on serial: String) async throws {
        try await adb(["-s", serial, "push", dex.path, Self.remoteDex])
        try await adb(["-s", serial, "forward", "tcp:\(Self.port)", "localabstract:sidebus-call"])
        // A bridge left over from an earlier run holds the socket name.
        _ = try? await adb(["-s", serial, "shell", "pkill", "-f", "CallBridge"])

        guard let adbPath = AdbWatcher.locateAdb() else { throw AdbWatcher.AdbError.adbNotFound }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: adbPath)
        process.arguments = ["-s", serial, "shell", "CLASSPATH=\(Self.remoteDex)", "exec", "app_process", "/", "CallBridge"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let log = self.log
        pipe.fileHandleForReading.readabilityHandler = { [self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            for line in String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init) {
                log.info("call bridge: \(line, privacy: .public)")
                if line == "ready" { Task { await self.report(.ready) } }
                if line.hasPrefix("error: ") { Task { await self.report(.failed(String(line.dropFirst(7)))) } }
            }
        }
        // Gone with the cable, or with the phone: the next check starts it again.
        process.terminationHandler = { [weak self] _ in
            pipe.fileHandleForReading.readabilityHandler = nil
            Task { await self?.bridgeExited() }
        }
        try process.run()
        self.process = process
    }

    private func bridgeExited() {
        process = nil
        report(serial == nil ? .noPhone : .starting)
    }

    private func stopBridge() async {
        process?.terminationHandler = nil
        process?.terminate()
        process = nil
        if let serial {
            _ = try? await adb(["-s", serial, "shell", "pkill", "-f", "CallBridge"])
            _ = try? await adb(["-s", serial, "forward", "--remove", "tcp:\(Self.port)"])
        }
    }

    private func report(_ status: Status) {
        statusHandler?(status)
    }

    @discardableResult
    private func adb(_ arguments: [String]) async throws -> String {
        guard let path = AdbWatcher.locateAdb() else { throw AdbWatcher.AdbError.adbNotFound }
        return try await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = arguments
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            try process.run()
            let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw AdbWatcher.AdbError.commandFailed(
                    arguments.joined(separator: " "), process.terminationStatus,
                    output.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            return output
        }.value
    }
}
