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
            Text("Appareils")
                .font(.title3.bold())

            Text(
                """
                Les tablettes visibles et celles déjà appairées, y compris hors ligne. \
                Désappairer efface l'empreinte du certificat : la prochaine connexion \
                redemandera un code, des deux côtés.
                """
            )
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            if devices.entries.isEmpty {
                Spacer()
                Text("Aucun appareil. Branchez une tablette, ou ajoutez son adresse ci dessous.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                Spacer()
            } else {
                // Une pile défilante plutôt qu'une `List` : celle ci calcule une hauteur de
                // rangée trop courte pour deux lignes de texte et rogne la première. Et
                // avec un seul appareil elle dessine des bandes vides sous la ligne, qu'on
                // prend pour des entrées en cours de chargement.
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(devices.entries.enumerated()), id: \.element.id) { index, entry in
                            if index > 0 { Divider() }
                            DeviceRow(entry: entry, devices: devices)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }

            Divider()

            ManualAddress(devices: devices)

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

/// Saisie manuelle de l'adresse. Indispensable sur les réseaux qui bloquent le multicast ou
/// qui isolent les clients entre eux : aucun code ne peut contourner ça, seule l'adresse
/// donnée à la main permet d'atteindre la tablette.
private struct ManualAddress: View {
    let devices: DeviceManager
    @State private var address = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Connexion par adresse IP")
                .font(.headline)

            Text(
                """
                Utile quand la tablette n'apparaît pas toute seule, sur un réseau qui bloque \
                le multicast. L'adresse est affichée sur la tablette, éventuellement suivie \
                de « : » et du port. Elle rejoint ensuite la liste ci dessus.
                """
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            HStack {
                TextField("192.168.1.20", text: $address)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(add)
                Button("Ajouter", action: add)
                    .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private func add() {
        devices.addManualPeer(address: address)
        address = ""
    }
}

private struct DeviceRow: View {
    let entry: DeviceEntry
    let devices: DeviceManager

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: entry.symbol)
                .font(.title3)
                .foregroundStyle(entry.isOnline ? .primary : .secondary)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if entry.isOnline {
                Button(actionLabel) { devices.perform(entry) }
            }

            if entry.isPaired {
                Button("Désappairer") { devices.unpair(entry.id) }
            }

            if entry.isManual, let identifier = devices.manualPeerID(forKey: entry.id) {
                Button("Oublier l'adresse") { devices.removeManualPeer(id: identifier) }
            }
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var actionLabel: String {
        switch entry.action {
        case .pair: return "Appairer"
        case .startSharing: return "Partager"
        case .stopSharing: return "Arrêter"
        case .none: return "—"
        }
    }

    private var subtitle: String {
        var parts = [entry.transportLabel]
        if entry.isManual { parts.append("adresse saisie") }
        if !entry.isPaired, entry.isOnline { parts.append("non appairé") }
        if let detail = entry.detail, !detail.isEmpty { parts.append(detail) }
        return parts.joined(separator: ", ")
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
