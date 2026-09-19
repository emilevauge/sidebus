import AppKit
import Foundation
import os

/// Replaces the running bundle with the one inside a downloaded DMG.
///
/// An app cannot rewrite itself while running, its binary is locked. So the work is handed
/// to a shell script staged in a temporary directory and spawned detached: it waits for our
/// process to exit, mounts the DMG, swaps the bundle, and launches the new one.
///
/// The swap moves the old bundle aside before copying, and puts it back when the copy
/// fails. At no point is the user left without an application.
enum SelfUpdater {

    enum UpdateError: Error, CustomStringConvertible {
        case notBundled
        case notWritable(String)
        case downloadFailed(Int?)
        case cannotStage
        case spawnFailed(Error)

        var description: String {
            switch self {
            case .notBundled:
                return "running from a plain binary, not a .app"
            case let .notWritable(path):
                return "\(path) is not writable"
            case let .downloadFailed(code):
                return "download failed (HTTP \(code.map(String.init) ?? "?"))"
            case .cannotStage:
                return "could not stage the helper script"
            case let .spawnFailed(error):
                return "helper could not start: \(error)"
            }
        }
    }

    private static let log = Logger(subsystem: "app.sidebus", category: "update")

    @MainActor
    static func run(dmgURL: URL, version: String) async {
        do {
            try await install(dmgURL: dmgURL, version: version)
        } catch {
            log.error("self update failed: \(String(describing: error), privacy: .public)")
            await report(error)
        }
    }

    @MainActor
    private static func install(dmgURL: URL, version: String) async throws {
        let bundlePath = Bundle.main.bundlePath
        guard bundlePath.hasSuffix(".app") else { throw UpdateError.notBundled }

        // A bundle opened straight from a mounted DMG is translocated and read only. So is
        // one in a directory the user cannot write. Better to say so than to fail halfway.
        let parent = (bundlePath as NSString).deletingLastPathComponent
        guard FileManager.default.isWritableFile(atPath: parent) else {
            throw UpdateError.notWritable(parent)
        }

        let staging = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("sidebus-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: staging, withIntermediateDirectories: true)

        let dmgPath = (staging as NSString).appendingPathComponent("Sidebus.dmg")
        let (downloaded, response) = try await URLSession.shared.download(from: dmgURL)
        let status = (response as? HTTPURLResponse)?.statusCode
        guard status == 200 else { throw UpdateError.downloadFailed(status) }
        try FileManager.default.moveItem(at: downloaded, to: URL(fileURLWithPath: dmgPath))

        let mountPath = (staging as NSString).appendingPathComponent("mount")
        let scriptPath = (staging as NSString).appendingPathComponent("install.sh")
        let logPath = (staging as NSString).appendingPathComponent("install.log")
        let backupPath = bundlePath + ".sidebus-update-backup"
        let pid = ProcessInfo.processInfo.processIdentifier

        let script = """
        #!/bin/zsh
        set -eu
        exec >\(quoted(logPath)) 2>&1

        BUNDLE=\(quoted(bundlePath))
        BACKUP=\(quoted(backupPath))
        MOUNT=\(quoted(mountPath))
        DMG=\(quoted(dmgPath))
        STAGING=\(quoted(staging))

        # Wait for Sidebus (pid \(pid)) to exit, up to 10 s.
        for _ in {1..100}; do
            kill -0 \(pid) 2>/dev/null || break
            sleep 0.1
        done

        mkdir -p "$MOUNT"
        hdiutil attach -nobrowse -mountpoint "$MOUNT" "$DMG"

        # Never destroy the installed bundle over a bad download.
        if [ ! -d "$MOUNT/Sidebus.app" ]; then
            hdiutil detach "$MOUNT" || true
            echo "bad DMG: no Sidebus.app inside" >&2
            exit 1
        fi

        rm -rf "$BACKUP"
        mv "$BUNDLE" "$BACKUP"
        if cp -R "$MOUNT/Sidebus.app" "$BUNDLE"; then
            rm -rf "$BACKUP"
        else
            rm -rf "$BUNDLE"
            mv "$BACKUP" "$BUNDLE"
            hdiutil detach "$MOUNT" || true
            echo "copy failed, rolled back" >&2
            exit 1
        fi

        # The download carries a quarantine flag. Gatekeeper checks the one on the bundle
        # root; nested resources are often mode 444 and make xattr complain for nothing.
        xattr -dr com.apple.quarantine "$BUNDLE" 2>/dev/null || true
        hdiutil detach "$MOUNT" || true
        open "$BUNDLE"
        rm -rf "$STAGING"
        """

        guard (try? script.write(toFile: scriptPath, atomically: true, encoding: .utf8)) != nil,
            chmod(scriptPath, 0o755) == 0
        else { throw UpdateError.cannotStage }

        // Foundation reparents the child to launchd when we exit, so it survives us.
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/zsh")
        helper.arguments = [scriptPath]
        do {
            try helper.run()
        } catch {
            throw UpdateError.spawnFailed(error)
        }

        log.info("installing \(version, privacy: .public), handing over to the helper")
        NSApp.terminate(nil)
    }

    /// POSIX single quoting: wrap in quotes, and close, escape, reopen around any quote.
    private static func quoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    @MainActor
    private static func report(_ error: Error) async {
        let alert = NSAlert()
        alert.messageText = "Update failed"
        alert.informativeText = """
            \(error)

            Download the new version from the release page instead.
            """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Close")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
