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

        Button("Connexion par adresse IP…") {
            askForAddress()
        }

        if !devices.manualPeers.isEmpty {
            Button("Oublier les adresses saisies") {
                devices.removeManualPeers()
            }
        }

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

    /// Saisie manuelle de l'adresse. Indispensable sur les réseaux qui bloquent le
    /// multicast ou qui isolent les clients entre eux : aucun code ne peut contourner ça.
    private func askForAddress() {
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = "Connexion par adresse IP"
        alert.informativeText =
            "Saisissez l'adresse affichée sur la tablette, éventuellement suivie de « : » et du port."
        alert.addButton(withTitle: "Connecter")
        alert.addButton(withTitle: "Annuler")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        field.placeholderString = "192.168.1.20"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        if alert.runModal() == .alertFirstButtonReturn {
            devices.addManualPeer(address: field.stringValue)
        }
    }
}
