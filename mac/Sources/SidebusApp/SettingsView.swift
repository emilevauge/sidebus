import AppKit
import CoreGraphics
import SidebusCore
import SwiftUI

/// The settings, in a popover from the panel's gear: one grouped form, a card per subject,
/// as in Calbar.
struct SettingsView: View {
    let devices: DeviceManager
    let phone: PhoneModel
    @Bindable var displays: DisplayMenuModel
    @Bindable var permissions: PermissionsModel
    let updates: UpdateChecker

    @State private var address = ""
    @State private var confirmingForgetAll = false
    @State private var handlesLinks = SettingsView.sidebusHandlesLinks()

    var body: some View {
        Form {
            screensSection
            addressSection
            phoneSection
            videoSection
            permissionsSection
            aboutSection
        }
        .formStyle(.grouped)
        .onAppear {
            permissions.refresh()
            handlesLinks = Self.sidebusHandlesLinks()
        }
        // Bounded height: the grouped form scrolls, so every section stays reachable.
        .frame(width: SidebusPanel.width, height: Self.height)
        .confirmationDialog("Forget every paired device?", isPresented: $confirmingForgetAll) {
            Button("Forget all", role: .destructive) { devices.unpairAll() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every tablet will ask for a pairing code again on its next connection.")
        }
    }

    /// 560 points, less on a screen too short to show that much.
    private static var height: CGFloat {
        let visible = NSScreen.main?.visibleFrame.height ?? 800
        return min(560, visible - 120)
    }

    // MARK: - Screens

    private var screensSection: some View {
        Section {
            if devices.pairedDevices.isEmpty && devices.entries.isEmpty {
                Text("No device yet. Plug a tablet in, or add its address below.")
                    .foregroundStyle(.secondary)
            }
            ForEach(devices.entries) { entry in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.name)
                        Text(entry.isOnline ? entry.transportLabel : (entry.detail ?? "offline"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if entry.isManual, let identifier = devices.manualPeerID(forKey: entry.id) {
                        Button("Forget address") { devices.removeManualPeer(id: identifier) }
                    }
                    if entry.isPaired {
                        Button("Unpair") { devices.unpair(entry.id) }
                    }
                }
            }
            if !devices.pairedDevices.isEmpty {
                Button("Forget all…", role: .destructive) { confirmingForgetAll = true }
            }
        } header: {
            Text("Screens")
        } footer: {
            footnote("Unpairing erases the certificate fingerprint: the next connection asks for a code again, on both sides.")
        }
    }

    private var addressSection: some View {
        Section {
            HStack {
                TextField("Address", text: $address, prompt: Text("192.168.1.20"))
                    .onSubmit(addAddress)
                Button("Add", action: addAddress)
                    .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        } header: {
            Text("Connect by IP address")
        } footer: {
            footnote("When a tablet does not show up on its own, on a network that blocks multicast. The tablet shows its address, optionally followed by \":\" and the port.")
        }
    }

    private func addAddress() {
        devices.addManualPeer(address: address)
        address = ""
    }

    // MARK: - Phone

    private var phoneSection: some View {
        Section {
            LabeledContent("Bluetooth", value: phone.isBluetoothConnected
                ? "Connected to \(phone.phoneName ?? "the phone")"
                : phone.phoneName.map { "\($0), not connected" } ?? "No phone paired")
            LabeledContent("Call audio") {
                Text(phone.summary).multilineTextAlignment(.trailing)
            }
            LabeledContent("Contacts") {
                HStack {
                    Text(phone.contactsNeedPermission
                        ? "Allow on the phone"
                        : "\(phone.contacts.count) numbers")
                    Button("Reload") { phone.refreshContacts() }
                        .controlSize(.small)
                }
            }
            if handlesLinks {
                LabeledContent("Phone links", value: "Opened by Sidebus")
            } else {
                LabeledContent("Phone links") {
                    Button("Open tel: links with Sidebus") {
                        NSWorkspace.shared.setDefaultApplication(
                            at: Bundle.main.bundleURL, toOpenURLsWithScheme: "tel"
                        ) { _ in
                            Task { @MainActor in handlesLinks = SettingsView.sidebusHandlesLinks() }
                        }
                    }
                }
            }
        } header: {
            Text("Phone")
        } footer: {
            footnote("Pair the phone from System Settings > Bluetooth, and with Sidebus. Bluetooth places and answers calls; their sound travels over Wi-Fi or USB. After each restart of the phone, plug it in over USB once, with USB debugging on. Its earpiece keeps playing the call quietly.")
        }
    }

    private static func sidebusHandlesLinks() -> Bool {
        guard let url = URL(string: "tel:0"),
              let handler = NSWorkspace.shared.urlForApplication(toOpen: url) else { return false }
        return handler.standardizedFileURL == Bundle.main.bundleURL.standardizedFileURL
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
                Text("Dedicated virtual display").tag(CGDirectDisplayID?.none)
                ForEach(displays.displays) { display in
                    Text(display.menuLabel).tag(CGDirectDisplayID?.some(display.id))
                }
            }
            if let error = displays.lastError {
                Text(error).foregroundStyle(.red)
            }
            HStack {
                Button("Refresh displays") { displays.refresh() }
                Spacer()
                Button(displays.captureLabel) { displays.toggleCapture() }
                    .disabled(displays.selectedID == nil && !displays.isCapturing)
            }
        } header: {
            Text("Video")
        } footer: {
            footnote("Resolution applies on the next connection; on Wi-Fi, 75 % is the default. By default each tablet gets a virtual display sized to its panel; naming an existing display mirrors it to every tablet instead.")
        }
    }

    // MARK: - Permissions

    private var permissionsSection: some View {
        Section {
            ForEach(permissions.permissions) { permission in
                HStack {
                    Image(systemName: permission.isGranted ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(permission.isGranted ? .green : .secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(permission.title)
                        if !permission.isGranted {
                            Text(permission.explanation).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if !permission.isGranted {
                        Button("Open") {
                            permission.request?()
                            permissions.openSettings(permission)
                        }
                    }
                }
            }
            if !permissions.allGranted {
                Button("Restart Sidebus") { Relauncher.relaunch() }
            }
        } header: {
            Text("Permissions")
        } footer: {
            footnote("A permission granted in System Settings takes effect on the next launch of Sidebus.")
        }
    }

    // MARK: - About

    private var aboutSection: some View {
        Section {
            LabeledContent("Version", value: updates.currentVersion)
            HStack {
                Button("Check for updates") { Task { await updates.checkManually() } }
                    .disabled(updates.isChecking)
                if updates.isChecking { ProgressView().controlSize(.small) }
                Spacer()
                if let result = updates.lastManualResult { resultLabel(result) }
            }
            if let release = updates.available {
                HStack {
                    Button("Install \(release.version)") { updates.install() }
                    Button("Release notes") { updates.openReleasePage() }
                }
            }
        } header: {
            Text("About")
        } footer: {
            footnote("Checked once a day, and when the Mac wakes up. Installing restarts Sidebus and stops any share in progress.")
        }
    }

    @ViewBuilder
    private func resultLabel(_ result: UpdateChecker.ManualResult) -> some View {
        switch result {
        case .upToDate:
            Label("Up to date", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case let .newer(release):
            Label("\(release.version) available", systemImage: "arrow.up.circle.fill").foregroundStyle(.orange)
        case let .failed(reason):
            Label(reason, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
        }
    }

    private func footnote(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}
