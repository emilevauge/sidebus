import AppKit
import ApplicationServices
import SidebusCore
import SwiftUI

/// State of the three permissions Sidebus needs, and a way to ask for them.
///
/// They only take effect after the app restarts: no point polling a check, it will never
/// turn true in the current session.
@MainActor
@Observable
final class PermissionsModel {

    struct Permission: Identifiable {
        let id: String
        let title: String
        let explanation: String
        let isGranted: Bool
        let settingsPane: String
        let request: (@MainActor () -> Void)?
    }

    private(set) var permissions: [Permission] = []

    init() {
        refresh()
    }

    var allGranted: Bool { permissions.allSatisfy(\.isGranted) }

    func refresh() {
        permissions = [
            Permission(
                id: "screen",
                title: "Screen Recording",
                explanation: "Without it Sidebus captures nothing, and the tablet stays black.",
                isGranted: ScreenCapturer.isAuthorized(),
                settingsPane: "com.apple.preference.security?Privacy_ScreenCapture",
                request: { ScreenCapturer.requestAuthorization() }
            ),
            Permission(
                id: "accessibility",
                title: "Accessibility",
                explanation: "Without it touches reach the Mac but never move the cursor.",
                isGranted: AccessibilityPermission.isTrusted(),
                settingsPane: "com.apple.preference.security?Privacy_Accessibility",
                request: { AccessibilityPermission.request() }
            ),
            Permission(
                id: "network",
                title: "Local Network",
                explanation: "Without it no tablet shows up over Wi-Fi, and no error says so.",
                // macOS publishes no API to read this state: it can only be noticed in use.
                isGranted: true,
                settingsPane: "com.apple.preference.security?Privacy_LocalNetwork",
                request: nil
            ),
        ]
    }

    func openSettings(_ permission: Permission) {
        guard let url = URL(string: "x-apple.systempreferences:\(permission.settingsPane)") else {
            return
        }
        NSWorkspace.shared.open(url)
    }
}

enum Relauncher {
    /// Restarts the app, the only way a granted permission takes effect.
    static func relaunch() {
        let url = Bundle.main.bundleURL
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, _ in
            Task { @MainActor in NSApp.terminate(nil) }
        }
    }
}
