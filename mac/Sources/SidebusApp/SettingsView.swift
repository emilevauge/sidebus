import AppKit
import CoreGraphics
import SidebusCore
import SwiftUI

/// The settings, in a popover from the panel's gear: one grouped form, a card per subject,
/// as in Calbar. Each card shows what matters and nothing more.
struct SettingsView: View {
    let devices: DeviceManager
    let phone: PhoneModel
    @Bindable var displays: DisplayMenuModel
    @Bindable var permissions: PermissionsModel
    let updates: UpdateChecker

    @State private var address = ""
    @State private var handlesLinks = SettingsView.sidebusHandlesLinks()

    var body: some View {
        Form {
            phoneSection
            screensSection
            videoSection
            permissionsSection
            aboutSection
        }
        .formStyle(.grouped)
        .onAppear {
            permissions.refresh()
            displays.refresh()
            handlesLinks = Self.sidebusHandlesLinks()
        }
        // Bounded height: the grouped form scrolls, so every section stays reachable.
        .frame(width: SidebusPanel.width, height: Self.height)
    }

    /// 560 points, less on a screen too short to show that much.
    private static var height: CGFloat {
        let visible = NSScreen.main?.visibleFrame.height ?? 800
        return min(560, visible - 120)
    }

    // MARK: - Phone

    private var phoneSection: some View {
        Section {
            LabeledContent("Phone") {
                StatusText(
                    phone.phoneName ?? "None paired",
                    ok: phone.isBluetoothConnected
                )
            }
            LabeledContent("Sound on the Mac") {
                StatusText(phone.callsAvailable ? "Ready" : "Plug the phone in once", ok: phone.callsAvailable)
            }
            LabeledContent("Contacts") {
                HStack(spacing: 8) {
                    Text(phone.contactsNeedPermission ? "Allow on the phone" : "\(phone.contacts.count)")
                        .foregroundStyle(.secondary)
                    Button("Reload") { phone.refreshContacts() }
                        .controlSize(.small)
                }
            }
            LabeledContent("Caller names") {
                StatusText(phone.callerNamesReadable ? "From the phone" : "Allow on the phone", ok: phone.callerNamesReadable)
            }
            LabeledContent("tel: links") {
                if handlesLinks {
                    Text("Sidebus").foregroundStyle(.secondary)
                } else {
                    Button("Use Sidebus") {
                        NSWorkspace.shared.setDefaultApplication(
                            at: Bundle.main.bundleURL, toOpenURLsWithScheme: "tel"
                        ) { _ in
                            Task { @MainActor in handlesLinks = SettingsView.sidebusHandlesLinks() }
                        }
                    }
                    .controlSize(.small)
                }
            }
        } header: {
            Text("Phone")
        } footer: {
            Footnote("Pair the phone over Bluetooth in System Settings. After each restart of the phone, plug it in over USB once.")
        }
    }

    private static func sidebusHandlesLinks() -> Bool {
        guard let url = URL(string: "tel:0"),
              let handler = NSWorkspace.shared.urlForApplication(toOpen: url) else { return false }
        return handler.standardizedFileURL == Bundle.main.bundleURL.standardizedFileURL
    }

    // MARK: - Screens

    private var screensSection: some View {
        Section {
            ForEach(devices.pairedDevices, id: \.deviceID) { device in
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(device.name)
                        Text(lastSeen(device))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Unpair") { devices.unpair(device.deviceID) }
                        .controlSize(.small)
                }
            }
            ForEach(devices.manualPeers) { peer in
                HStack {
                    Text(peer.name)
                    Spacer()
                    Button("Forget") { devices.removeManualPeer(id: peer.id) }
                        .controlSize(.small)
                }
            }
            HStack {
                TextField("Add by address", text: $address, prompt: Text("192.168.1.20"))
                    .onSubmit(addAddress)
                Button("Add", action: addAddress)
                    .controlSize(.small)
                    .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        } header: {
            Text("Paired devices")
        } footer: {
            Footnote("Add a tablet by its address when the network hides it.")
        }
    }

    private func lastSeen(_ device: PairedDevice) -> String {
        let online = devices.entries.contains { $0.id == device.deviceID && $0.isOnline }
        if online { return "In sight" }
        return "Seen \(device.lastSeen.formatted(.relative(presentation: .named)))"
    }

    private func addAddress() {
        devices.addManualPeer(address: address)
        address = ""
    }

    // MARK: - Video

    private var videoSection: some View {
        Section {
            Picker("Resolution", selection: Binding(
                get: { devices.resolutionScale },
                set: { devices.setResolutionScale($0) }
            )) {
                Text("Native").tag(1.0)
                Text("75 %").tag(0.75)
                Text("50 %").tag(0.5)
            }
            Picker("Display", selection: $displays.selectedID) {
                Text("A virtual display per tablet").tag(CGDirectDisplayID?.none)
                ForEach(displays.displays) { display in
                    Text("Mirror \(display.menuLabel)").tag(CGDirectDisplayID?.some(display.id))
                }
            }
            if let error = displays.lastError {
                Text(error).foregroundStyle(.red)
            }
        } header: {
            Text("Screen sharing")
        } footer: {
            Footnote("Applies on the next connection.")
        }
    }

    // MARK: - Permissions

    private var permissionsSection: some View {
        Section {
            if permissions.allGranted {
                LabeledContent("Permissions") {
                    StatusText("All granted", ok: true)
                }
            } else {
                ForEach(permissions.permissions.filter { !$0.isGranted }) { permission in
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(permission.title)
                            Text(permission.explanation).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Open") {
                            permission.request?()
                            permissions.openSettings(permission)
                        }
                        .controlSize(.small)
                    }
                }
                Button("Restart Sidebus") { Relauncher.relaunch() }
            }
        } header: {
            Text("Permissions")
        }
    }

    // MARK: - About

    private var aboutSection: some View {
        Section {
            LabeledContent("Version") {
                HStack(spacing: 8) {
                    Text(updates.currentVersion).foregroundStyle(.secondary).monospacedDigit()
                    if updates.isChecking {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Check") { Task { await updates.checkManually() } }
                            .controlSize(.small)
                    }
                }
            }
            if let release = updates.available {
                LabeledContent("Sidebus \(release.version)") {
                    HStack(spacing: 8) {
                        Button("Notes") { updates.openReleasePage() }.controlSize(.small)
                        Button("Install") { updates.install() }.controlSize(.small)
                    }
                }
            } else if let result = updates.lastManualResult {
                resultRow(result)
            }
        } header: {
            Text("About")
        }
    }

    @ViewBuilder
    private func resultRow(_ result: UpdateChecker.ManualResult) -> some View {
        switch result {
        case .upToDate:
            StatusText("Up to date", ok: true)
        case let .newer(release):
            Text("\(release.version) available").foregroundStyle(.orange)
        case let .failed(reason):
            Text(reason).foregroundStyle(.red)
        }
    }
}

/// A short state with a coloured dot: green when fine, orange otherwise.
private struct StatusText: View {
    let text: String
    let ok: Bool

    init(_ text: String, ok: Bool) {
        self.text = text
        self.ok = ok
    }

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(ok ? Color.green : Color.orange).frame(width: 7, height: 7)
            Text(text).foregroundStyle(.secondary)
        }
    }
}

private struct Footnote: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}
