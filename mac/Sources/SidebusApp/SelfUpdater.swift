import AppKit
import Foundation
import os
import Security

/// Replaces the running bundle with the one inside a downloaded DMG.
///
/// An app cannot rewrite itself while running, its binary is locked. So the work is handed
/// to a shell script staged in a temporary directory and spawned detached: it waits for our
/// process to exit, mounts the DMG, checks the new bundle's signature, swaps the bundle,
/// and launches the new one.
///
/// The new bundle must satisfy the running app's designated requirement: same bundle id,
/// signed with the same certificate. The script strips the quarantine flag, so Gatekeeper
/// never looks at the download, and this check is what stops a tampered release.
///
/// The swap moves the old bundle aside before copying. Whatever fails after we quit, the
/// script puts the old bundle back and relaunches it. At no point is the user left without
/// an application.
enum SelfUpdater {

    enum UpdateError: Error, CustomStringConvertible {
        case notBundled
        case notWritable(String)
        case downloadFailed(Int?)
        case unsigned
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
            case .unsigned:
                return "this copy of Sidebus is not signed with a certificate, so the update could not be verified"
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
        guard let requirement = designatedRequirement() else { throw UpdateError.unsigned }

        let staging = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("sidebus-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: staging, withIntermediateDirectories: true)

        let dmgPath = (staging as NSString).appendingPathComponent("Sidebus.dmg")
        let (downloaded, response) = try await URLSession.shared.download(from: dmgURL)
        let status = (response as? HTTPURLResponse)?.statusCode
        guard status == 200 else { throw UpdateError.downloadFailed(status) }
        try FileManager.default.moveItem(at: downloaded, to: URL(fileURLWithPath: dmgPath))

        let scriptPath = (staging as NSString).appendingPathComponent("install.sh")
        let script = installScript(
            bundlePath: bundlePath,
            dmgPath: dmgPath,
            staging: staging,
            pid: ProcessInfo.processInfo.processIdentifier,
            requirement: requirement
        )

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

    /// The running app's designated requirement, as `codesign -d -r-` prints it: its bundle
    /// id and the certificate it is signed with. Nil for an unsigned or ad hoc build, whose
    /// requirement pins its own hash and that no update could satisfy.
    static func designatedRequirement() -> String? {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var requirement: SecRequirement?
        var text: CFString?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
            SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
            SecCodeCopyDesignatedRequirement(staticCode, [], &requirement) == errSecSuccess,
            let requirement,
            SecRequirementCopyString(requirement, [], &text) == errSecSuccess, let text
        else { return nil }
        let string = text as String
        return string.contains("cdhash") ? nil : string
    }

    /// The helper script. It does not use `set -e`: every step that matters goes through
    /// `fail`, which puts the installed bundle back if it was moved, detaches the DMG,
    /// relaunches the app and exits 1, since Sidebus has already quit by then.
    static func installScript(
        bundlePath: String,
        dmgPath: String,
        staging: String,
        pid: Int32,
        requirement: String
    ) -> String {
        let mountPath = (staging as NSString).appendingPathComponent("mount")
        let logPath = (staging as NSString).appendingPathComponent("install.log")
        let backupPath = bundlePath + ".sidebus-update-backup"
        return """
        #!/bin/zsh
        set -u
        exec >\(quoted(logPath)) 2>&1

        BUNDLE=\(quoted(bundlePath))
        BACKUP=\(quoted(backupPath))
        MOUNT=\(quoted(mountPath))
        DMG=\(quoted(dmgPath))
        STAGING=\(quoted(staging))
        NEW="$MOUNT/Sidebus.app"

        fail() {
            echo "update failed: $1" >&2
            hdiutil detach "$MOUNT" -quiet 2>/dev/null
            if [ ! -d "$BUNDLE" ] && [ -d "$BACKUP" ]; then mv "$BACKUP" "$BUNDLE"; fi
            open "$BUNDLE"
            exit 1
        }

        # Wait for Sidebus (pid \(pid)) to exit, up to 10 s, then stop it: opening the bundle
        # while the old process lives would only bring that one forward.
        for _ in {1..100}; do
            kill -0 \(pid) 2>/dev/null || break
            sleep 0.1
        done
        if kill -0 \(pid) 2>/dev/null; then
            kill \(pid)
            sleep 1
            kill -9 \(pid) 2>/dev/null
        fi

        mkdir -p "$MOUNT" || fail "cannot create the mount point"
        hdiutil attach -nobrowse -readonly -mountpoint "$MOUNT" "$DMG" || fail "cannot mount the DMG"

        # Never destroy the installed bundle over a bad download, nor replace it with anything
        # but Sidebus signed with the same certificate: the quarantine flag is stripped below,
        # so Gatekeeper will not check it.
        [ -x "$NEW/Contents/MacOS/SidebusApp" ] || fail "no Sidebus.app in the DMG"
        codesign --verify --deep --strict -R=\(quoted(requirement)) "$NEW" \\
            || fail "the new bundle's signature does not match the installed app"

        rm -rf "$BACKUP"
        mv "$BUNDLE" "$BACKUP" || fail "cannot move the installed bundle aside"
        if ! cp -R "$NEW" "$BUNDLE"; then
            rm -rf "$BUNDLE"
            fail "copy failed, rolled back"
        fi
        rm -rf "$BACKUP"

        # The download carries a quarantine flag. Gatekeeper checks the one on the bundle
        # root; nested resources are often mode 444 and make xattr complain for nothing.
        xattr -dr com.apple.quarantine "$BUNDLE" 2>/dev/null
        hdiutil detach "$MOUNT" -quiet
        open "$BUNDLE"
        rm -rf "$STAGING"
        """
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
