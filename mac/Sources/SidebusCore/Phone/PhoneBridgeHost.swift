import Foundation
import os

/// What only USB can do for calls: start the call helper (android/callbridge) on the
/// phone, as the adb shell, since no app may reach call audio. Started detached from
/// adb, the helper outlives the cable and runs until the phone restarts, so one plug after
/// each restart is enough. Also forwards the phone's call channel, so that a plugged phone
/// is reached over USB rather than Wi-Fi.
public actor PhoneBridgeHost {

    private static let remoteDex = "/data/local/tmp/sidebus-callbridge.dex"
    private static let remoteLog = "/data/local/tmp/sidebus-callbridge.log"

    private let dex: URL
    private var serial: String?
    private var onUSB: (@Sendable (Bool) -> Void)?
    private var watch: Task<Void, Never>?
    private let log = Logger(subsystem: "app.sidebus", category: "phone")

    /// `dex` is CallBridge built by android/callbridge/build.sh, shipped in the app.
    public init(dex: URL) {
        self.dex = dex
    }

    /// Looks for a plugged phone every few seconds. `onUSB` says whether one is plugged
    /// and its call channel forwarded.
    public func start(onUSB: @escaping @Sendable (Bool) -> Void) {
        self.onUSB = onUSB
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
        if serial != nil {
            _ = try? await adb(["forward", "--remove", "tcp:\(Sidebus.callPort)"])
        }
    }

    private func check() async {
        guard let phone = await findPhone() else {
            if serial != nil { onUSB?(false) }
            serial = nil
            return
        }
        do {
            if try await !helperRuns(on: phone) {
                try await startHelper(on: phone)
            }
            if serial != phone {
                try await adb(["-s", phone, "forward", "tcp:\(Sidebus.callPort)", "tcp:\(Sidebus.callPort)"])
                serial = phone
                onUSB?(true)
            }
        } catch {
            log.error("call helper: \(String(describing: error), privacy: .public)")
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

    private func helperRuns(on serial: String) async throws -> Bool {
        let output = (try? await adb(["-s", serial, "shell", "pgrep", "-f", "CallBridge"])) ?? ""
        return !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func startHelper(on serial: String) async throws {
        log.info("starting the call helper on \(serial, privacy: .public)")
        try await adb(["-s", serial, "push", dex.path, Self.remoteDex])
        // setsid takes it out of the adb session, which ends with the cable.
        try await adb([
            "-s", serial, "shell",
            """
            setsid sh -c 'CLASSPATH=\(Self.remoteDex) exec app_process / CallBridge \
            > \(Self.remoteLog) 2>&1 < /dev/null' &
            """,
        ])
        // The app's call service relays the helper to the Mac. HyperOS does not let it
        // start on its own at boot, so start it here.
        _ = try? await adb(["-s", serial, "shell", "am", "start", "-n", "app.sidebus/.phone.PermissionsActivity"])
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
