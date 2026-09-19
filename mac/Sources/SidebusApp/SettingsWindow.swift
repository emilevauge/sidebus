import AppKit
import CoreGraphics
import SidebusCore
import SwiftUI

/// Fenêtre de réglages. Ce qui était éparpillé dans le menu vit ici : le menu ne garde que
/// la liste des appareils et les gestes qui s'y rapportent.
struct SettingsWindow: View {
    let devices: DeviceManager
    @Bindable var displays: DisplayMenuModel
    @Bindable var permissions: PermissionsModel

    var body: some View {
        TabView {
            DeviceSettings(devices: devices)
                .tabItem { Label("Appareils", systemImage: "ipad.and.iphone") }

            VideoSettings(devices: devices, displays: displays)
                .tabItem { Label("Vidéo", systemImage: "rectangle.on.rectangle") }

            PermissionsView(model: permissions)
                .tabItem { Label("Autorisations", systemImage: "lock.shield") }
        }
        .frame(width: 560, height: 420)
    }
}

// MARK: - Appareils

private struct DeviceSettings: View {
    let devices: DeviceManager
    @State private var confirmingAll = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Appareils appairés")
                .font(.title3.bold())

            Text(
                """
                Désappairer efface l'empreinte du certificat de la tablette. La prochaine \
                connexion redemandera un code, des deux côtés.
                """
            )
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            if devices.pairedDevices.isEmpty {
                Spacer()
                Text("Aucun appareil appairé. Cliquez sur une tablette dans le menu Sidebus.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                Spacer()
            } else {
                List(devices.pairedDevices) { device in
                    DeviceRow(device: device, devices: devices)
                }
                // Pas de fond alterné : avec un seul appareil il dessine quatre bandes
                // vides sous la ligne, et on croit à des entrées en cours de chargement.
                .listStyle(.inset)
            }

            HStack {
                Spacer()
                Button("Tout oublier", role: .destructive) { confirmingAll = true }
                    .disabled(devices.pairedDevices.isEmpty)
            }
        }
        .padding(20)
        .confirmationDialog(
            "Oublier tous les appareils appairés ?",
            isPresented: $confirmingAll
        ) {
            Button("Tout oublier", role: .destructive) { devices.unpairAll() }
            Button("Annuler", role: .cancel) {}
        } message: {
            Text("Chaque tablette redemandera un code d'appairage à sa prochaine connexion.")
        }
    }
}

private struct DeviceRow: View {
    let device: PairedDevice
    let devices: DeviceManager

    /// Ligne correspondante dans la liste vivante, quand l'appareil est visible.
    private var entry: DeviceEntry? {
        devices.entries.first { $0.id == device.deviceID }
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: entry?.symbol ?? "ipad.slash")
                .font(.title3)
                .foregroundStyle(entry?.isOnline == true ? .primary : .secondary)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(device.name)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if let entry, entry.isOnline {
                Button(entry.isSharing ? "Arrêter" : "Partager") {
                    devices.perform(entry)
                }
            }

            Button("Désappairer") {
                devices.unpair(device.deviceID)
            }
        }
        .padding(.vertical, 4)
    }

    private var subtitle: String {
        guard let entry, entry.isOnline else {
            return "hors ligne, vu en \(Self.transport(device.lastTransport))"
        }
        if let detail = entry.detail, !detail.isEmpty {
            return "\(entry.transportLabel), \(detail)"
        }
        return entry.transportLabel
    }

    private static func transport(_ kind: TransportKind?) -> String {
        switch kind {
        case .usb: return "USB"
        case .wifi: return "Wi-Fi"
        case nil: return "transport inconnu"
        }
    }
}

// MARK: - Vidéo

private struct VideoSettings: View {
    let devices: DeviceManager
    @Bindable var displays: DisplayMenuModel

    var body: some View {
        Form {
            Section {
                Picker("Résolution", selection: Binding(
                    get: { devices.resolutionScale },
                    set: { devices.setResolutionScale($0) }
                )) {
                    Text("Native").tag(1.0)
                    Text("75 %").tag(0.75)
                    Text("50 %").tag(0.5)
                }
                Text(
                    """
                    Appliqué à la prochaine connexion. En Wi-Fi, 75 % est le défaut quand \
                    rien n'est choisi.
                    """
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section("Écran capturé") {
                Picker("Écran", selection: $displays.selectedID) {
                    Text("Écran virtuel dédié").tag(CGDirectDisplayID?.none)
                    ForEach(displays.displays) { display in
                        Text(display.menuLabel).tag(CGDirectDisplayID?.some(display.id))
                    }
                }
                Text(
                    """
                    Par défaut Sidebus crée un écran virtuel par tablette, à la taille de \
                    sa dalle. Désigner un écran existant le recopie plutôt, sur toutes les \
                    tablettes à la fois.
                    """
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                if let error = displays.lastError {
                    Text(error).foregroundStyle(.red)
                }

                Button("Actualiser la liste") { displays.refresh() }
            }

            Section("Diagnostic") {
                Button(displays.captureLabel) { displays.toggleCapture() }
                    .disabled(displays.selectedID == nil && !displays.isCapturing)
                if displays.isCapturing {
                    Text("Sortie : \(DisplayMenuModel.outputPath)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }
}
