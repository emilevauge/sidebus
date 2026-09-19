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

struct PermissionsView: View {
    @Bindable var model: PermissionsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Permissions")
                .font(.title2.bold())

            Text(
                """
                macOS asks for your agreement on each one. They only take effect on the \
                next launch of Sidebus.
                """
            )
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            ForEach(model.permissions) { permission in
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: permission.isGranted ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(permission.isGranted ? .green : .secondary)
                        .font(.title3)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(permission.title).font(.headline)
                        Text(permission.explanation)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer()

                    Button("Open Settings") {
                        permission.request?()
                        model.openSettings(permission)
                    }
                }
            }

            Divider()

            HStack {
                Button("Check again") { model.refresh() }
                Spacer()
                Button("Restart Sidebus") { Self.relaunch() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 520)
    }

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
