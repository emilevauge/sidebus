import AppKit
import CoreGraphics
import SwiftUI

struct MenuContent: View {
    @Bindable var model: DisplayMenuModel
    let connection: ConnectionModel
    let permissions: PermissionsModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if let lastError = model.lastError {
            Text(lastError)
        }

        if model.displays.isEmpty {
            Text("Aucun écran détecté")
        } else {
            Picker("Écran capturé", selection: $model.selectedID) {
                Text("Aucun").tag(CGDirectDisplayID?.none)
                ForEach(model.displays) { display in
                    Text(display.menuLabel).tag(CGDirectDisplayID?.some(display.id))
                }
            }
            .pickerStyle(.inline)
        }

        Divider()

        Text(connection.menuLabel)

        if let refusal = connection.pairing.lastRefusal {
            Text(refusal)
        }

        Picker("Résolution", selection: Binding(
            get: { connection.resolutionScale },
            set: { connection.setResolutionScale($0) }
        )) {
            Text("Native").tag(1.0)
            Text("75 %").tag(0.75)
            Text("50 %").tag(0.5)
        }
        .pickerStyle(.inline)

        Button(connection.sharingLabel) {
            connection.toggleSharing()
        }

        Button("Oublier les appareils appairés") {
            connection.forgetPairedDevices()
        }

        Button("Connexion par adresse IP…") {
            askForAddress()
        }

        if !connection.manualPeers.isEmpty {
            Button("Oublier les adresses saisies") {
                connection.removeManualPeers()
            }
        }

        Divider()

        Button(model.captureLabel) {
            model.toggleCapture()
        }
        .disabled(model.selectedID == nil && !model.isCapturing)

        if model.isCapturing {
            Text("Sortie : \(DisplayMenuModel.outputPath)")
        }

        Divider()

        Button(permissions.allGranted ? "Autorisations…" : "Autorisations manquantes…") {
            permissions.refresh()
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: "permissions")
        }

        Button("Actualiser la liste") {
            model.refresh()
        }

        Divider()

        Button("Quitter Sidebus") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
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
            connection.addManualPeer(address: field.stringValue)
        }
    }
}
