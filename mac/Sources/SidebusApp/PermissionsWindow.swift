import AppKit
import ApplicationServices
import SidebusCore
import SwiftUI

/// État des trois autorisations que Sidebus doit obtenir, et moyen de les demander.
///
/// Elles ne prennent effet qu'après relance de l'application : inutile de boucler sur une
/// vérification, elle ne passera jamais à vrai dans la session courante.
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
                title: "Enregistrement de l'écran",
                explanation: "Sans elle, Sidebus ne peut rien capturer : la tablette reste noire.",
                isGranted: ScreenCapturer.isAuthorized(),
                settingsPane: "com.apple.preference.security?Privacy_ScreenCapture",
                request: { ScreenCapturer.requestAuthorization() }
            ),
            Permission(
                id: "accessibility",
                title: "Accessibilité",
                explanation: "Sans elle, les touchers arrivent au Mac mais ne bougent pas le curseur.",
                isGranted: AccessibilityPermission.isTrusted(),
                settingsPane: "com.apple.preference.security?Privacy_Accessibility",
                request: { AccessibilityPermission.request() }
            ),
            Permission(
                id: "network",
                title: "Réseau local",
                explanation: "Sans elle, aucune tablette n'apparaît en Wi-Fi, et sans message d'erreur.",
                // macOS ne publie pas d'API pour lire cet état : on ne peut que le
                // constater à l'usage.
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
            Text("Autorisations")
                .font(.title2.bold())

            Text(
                """
                macOS demande votre accord pour chacune. Elles ne prennent effet qu'au \
                lancement suivant de Sidebus.
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

                    Button("Réglages") {
                        permission.request?()
                        model.openSettings(permission)
                    }
                }
            }

            Divider()

            HStack {
                Button("Revérifier") { model.refresh() }
                Spacer()
                Button("Relancer Sidebus") { Self.relaunch() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 520)
    }

    /// Relance l'application, seul moyen de prendre en compte une autorisation accordée.
    static func relaunch() {
        let url = Bundle.main.bundleURL
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, _ in
            Task { @MainActor in NSApp.terminate(nil) }
        }
    }
}
