import AppKit
import SwiftUI

struct MenuContent: View {
    let devices: DeviceManager
    let phone: PhoneModel
    let permissions: PermissionsModel
    let updates: UpdateChecker
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(devices.summary)

        if let release = updates.available {
            Button {
                updates.install()
            } label: {
                Label("Sidebus \(release.version) is available", systemImage: "arrow.down.circle.fill")
            }
        }

        if let refusal = devices.lastRefusal {
            Text(refusal)
        }

        Divider()

        Section("Devices") {
            if devices.entries.isEmpty {
                Text("No device")
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

        Section("Phone") {
            if phone.isInCall {
                Button("Show Call with \(phone.peer ?? "…")") { DialerPanel.shared.show() }
                Button("Hang Up") { phone.hangUp() }
            } else {
                Button("Call…") { DialerPanel.shared.show() }
                    .disabled(!phone.isBluetoothConnected)
                Text(phone.summary)
            }
        }

        Divider()

        Button("Settings…") {
            NSApp.activate(ignoringOtherApps: true)
            permissions.refresh()
            openWindow(id: "settings")
        }
        .keyboardShortcut(",")

        Divider()

        Button("Quit Sidebus") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }

    /// Name, transport, then the state on a second line when there is something to say. A
    /// multiline `Text` sits perfectly well in an `NSMenu`.
    private func label(for entry: DeviceEntry) -> String {
        var text = entry.name
        if entry.isOnline { text += " (\(entry.transportLabel))" }
        if let detail = entry.detail, !detail.isEmpty { text += "\n\(detail)" }
        return text
    }
}
