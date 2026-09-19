import AppKit
import SwiftUI

struct MenuContent: View {
    let devices: DeviceManager
    let permissions: PermissionsModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(devices.summary)

        if let refusal = devices.lastRefusal {
            Text(refusal)
        }

        Divider()

        Section("Appareils") {
            if devices.entries.isEmpty {
                Text("Aucun appareil")
            }

            ForEach(devices.entries) { entry in
                Button {
                    devices.perform(entry)
                } label: {
                    Label(label(for: entry), systemImage: entry.symbol)
                }
                .disabled(entry.action == .none)
            }
        }

        Divider()

        Button("Réglages…") {
            NSApp.activate(ignoringOtherApps: true)
            permissions.refresh()
            openWindow(id: "settings")
        }
        .keyboardShortcut(",")

        Divider()

        Button("Quitter Sidebus") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }

    /// Nom, transport, puis l'état sur une deuxième ligne quand il y a quelque chose à
    /// dire. Un `Text` multiligne passe très bien dans un `NSMenu`.
    private func label(for entry: DeviceEntry) -> String {
        var text = entry.name
        if entry.isOnline { text += " (\(entry.transportLabel))" }
        if let detail = entry.detail, !detail.isEmpty { text += "\n\(detail)" }
        return text
    }
}
