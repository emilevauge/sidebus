import CryptoKit
import Foundation
import Security
import os

/// What only USB can do for calls: start the call helper (android/callbridge) on the
/// phone, as the adb shell, since no app may reach call audio. Started detached from
/// adb, the helper outlives the cable and runs until the phone restarts, so one plug after
/// each restart is enough. Also forwards the phone's call channel, so that a plugged phone
/// is reached over USB rather than Wi-Fi.
public actor PhoneBridgeHost {

    private static let remoteDex = "/data/local/tmp/sidebus-callbridge.dex"
    private static let remoteLog = "/data/local/tmp/sidebus-callbridge.log"
    /// The helper's secret, kept where apps cannot read, for later plugs. See CallBridge.java.
    private static let remoteSecret = "/data/local/tmp/sidebus-callbridge.secret"

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
            guard serial != phone else { return }
            var secret = try await storedSecret(on: phone)
            let runs = try await helperRuns(on: phone)
            let current = try await helperIsCurrent(on: phone)
            if secret == nil || !runs || !current {
                secret = try await startHelper(on: phone)
            }
            // The app proves itself to the helper with this secret. HyperOS also keeps the
            // app's call service from starting on its own at boot: this starts it.
            try await adb([
                "-s", phone, "shell", "am", "start", "-n", "app.sidebus/.phone.HelperActivity",
                "--es", "secret", secret ?? "",
            ])
            try await adb(["-s", phone, "forward", "tcp:\(Sidebus.callPort)", "tcp:\(Sidebus.callPort)"])
            serial = phone
            onUSB?(true)
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

    /// Whether the helper on the phone is the one this app carries: a helper started by
    /// an older Sidebus keeps running until the phone restarts, unless replaced.
    private func helperIsCurrent(on serial: String) async throws -> Bool {
        guard let local = try? Data(contentsOf: dex) else { return true }
        let digest = Insecure.MD5.hash(data: local).map { String(format: "%02x", $0) }.joined()
        let remote = (try? await adb(["-s", serial, "shell", "md5sum", Self.remoteDex])) ?? ""
        return remote.hasPrefix(digest)
    }

    private func storedSecret(on serial: String) async throws -> String? {
        let output = (try? await adb(["-s", serial, "shell", "cat", Self.remoteSecret])) ?? ""
        let secret = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return secret.count == 64 && secret.allSatisfy(\.isHexDigit) ? secret : nil
    }

    /// Starts a fresh helper, with a fresh secret, and returns the secret.
    private func startHelper(on serial: String) async throws -> String {
        log.info("starting the call helper on \(serial, privacy: .public)")
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw AdbWatcher.AdbError.commandFailed("SecRandomCopyBytes", 1, "no randomness")
        }
        let secret = bytes.map { String(format: "%02x", $0) }.joined()

        _ = try? await adb(["-s", serial, "shell", "pkill", "-f", "CallBridge"])
        try await adb(["-s", serial, "push", dex.path, Self.remoteDex])
        try await adb([
            "-s", serial, "shell",
            "umask 077; echo \(secret) > \(Self.remoteSecret)",
        ])
        // setsid takes it out of the adb session, which ends with the cable. Other apps
        // cannot read a shell process's command line, so the secret may pass there.
        try await adb([
            "-s", serial, "shell",
            """
            setsid sh -c 'CLASSPATH=\(Self.remoteDex) exec app_process / CallBridge \(secret) \
            > \(Self.remoteLog) 2>&1 < /dev/null' &
            """,
        ])
        return secret
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
