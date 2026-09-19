import AppKit
import CoreGraphics
import SidebusCore
import SwiftUI

/// Settings window. What used to be scattered through the menu lives here: the menu keeps
/// only the device list and the gestures that go with it.
struct SettingsWindow: View {
    let devices: DeviceManager
    @Bindable var displays: DisplayMenuModel
    @Bindable var permissions: PermissionsModel

    var body: some View {
        TabView {
            DeviceSettings(devices: devices)
                .tabItem { Label("Devices", systemImage: "ipad.and.iphone") }

            VideoSettings(devices: devices, displays: displays)
                .tabItem { Label("Video", systemImage: "rectangle.on.rectangle") }

            PermissionsView(model: permissions)
                .tabItem { Label("Permissions", systemImage: "lock.shield") }
        }
        .frame(width: 560, height: 420)
    }
}

// MARK: - Devices

private struct DeviceSettings: View {
    let devices: DeviceManager
    @State private var confirmingAll = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Devices")
                .font(.title3.bold())

            Text(
                """
                The tablets in sight and the ones already paired, offline included. \
                Unpairing erases the certificate fingerprint, so the next connection asks \
                for a code again, on both sides.
                """
            )
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            if devices.entries.isEmpty {
                Spacer()
                Text("No device. Plug a tablet in, or add its address below.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                Spacer()
            } else {
                // A scrolling stack rather than a `List`: the latter computes a row height too
                // short for two lines of text and clips the first one. And with a single
                // device it draws empty bands below the row, which read as entries still
                // loading.
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
                Button("Forget all", role: .destructive) { confirmingAll = true }
                    .disabled(devices.pairedDevices.isEmpty)
            }
        }
        .padding(20)
        .confirmationDialog(
            "Forget every paired device?",
            isPresented: $confirmingAll
        ) {
            Button("Forget all", role: .destructive) { devices.unpairAll() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every tablet will ask for a pairing code again on its next connection.")
        }
    }
}

/// Typing the address by hand. Essential on networks that block multicast or isolate their
/// clients: no code can work around that, only an address given by hand reaches the tablet.
private struct ManualAddress: View {
    let devices: DeviceManager
    @State private var address = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Connect by IP address")
                .font(.headline)

            Text(
                """
                Useful when the tablet does not show up on its own, on a network that \
                blocks multicast. The address is displayed on the tablet, optionally \
                followed by \":\" and the port. It then joins the list above.
                """
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            HStack {
                TextField("192.168.1.20", text: $address)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(add)
                Button("Add", action: add)
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
                Button("Unpair") { devices.unpair(entry.id) }
            }

            if entry.isManual, let identifier = devices.manualPeerID(forKey: entry.id) {
                Button("Forget address") { devices.removeManualPeer(id: identifier) }
            }
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var actionLabel: String {
        switch entry.action {
        case .pair: return "Pair"
        case .startSharing: return "Share"
        case .stopSharing: return "Stop"
        case .none: return "—"
        }
    }

    private var subtitle: String {
        var parts = [entry.transportLabel]
        if entry.isManual { parts.append("typed address") }
        if !entry.isPaired, entry.isOnline { parts.append("not paired") }
        if let detail = entry.detail, !detail.isEmpty { parts.append(detail) }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Video

private struct VideoSettings: View {
    let devices: DeviceManager
    @Bindable var displays: DisplayMenuModel

    var body: some View {
        Form {
            Section {
                Picker("Resolution", selection: Binding(
                    get: { devices.resolutionScale },
                    set: { devices.setResolutionScale($0) }
                )) {
                    Text("Native").tag(1.0)
                    Text("75 %").tag(0.75)
                    Text("50 %").tag(0.5)
                }
                Text(
                    """
                    Applied on the next connection. On Wi-Fi, 75 % is the default when \
                    nothing is chosen.
                    """
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section("Captured display") {
                Picker("Display", selection: $displays.selectedID) {
                    Text("Dedicated virtual display").tag(CGDirectDisplayID?.none)
                    ForEach(displays.displays) { display in
                        Text(display.menuLabel).tag(CGDirectDisplayID?.some(display.id))
                    }
                }
                Text(
                    """
                    By default Sidebus creates one virtual display per tablet, sized to its \
                    panel. Naming an existing display mirrors that instead, to every tablet \
                    at once.
                    """
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                if let error = displays.lastError {
                    Text(error).foregroundStyle(.red)
                }

                Button("Refresh the list") { displays.refresh() }
            }

            Section("Diagnostics") {
                Button(displays.captureLabel) { displays.toggleCapture() }
                    .disabled(displays.selectedID == nil && !displays.isCapturing)
                if displays.isCapturing {
                    Text("Output: \(DisplayMenuModel.outputPath)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }
}
