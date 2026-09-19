import AppKit
import SidebusCore
import SwiftUI

struct MenuContent: View {
    let devices: DeviceManager
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

        // Online and paired devices only. A camera needs a link, and a link needs pairing.
        let filmable = devices.entries.filter { $0.isOnline && $0.isPaired }
        if !filmable.isEmpty {
            Divider()

            Section("Cameras") {
                ForEach(filmable) { entry in
                    if entry.cameras.isEmpty {
                        // Never connected long enough to hear CAMERA_LIST. Offer the link
                        // anyway: the tablet will say what it has, and its back camera
                        // starts on its own.
                        Button {
                            devices.startCamera(entry.id, choice: .preferred)
                            openWindow(id: "camera")
                        } label: {
                            Label("Camera (\(entry.name))", systemImage: "web.camera")
                        }
                    }
                    ForEach(entry.cameras) { camera in
                        Button {
                            if entry.activeCamera == camera {
                                devices.stopCamera(entry.id)
                            } else {
                                devices.startCamera(entry.id, choice: .id(camera.id))
                                openWindow(id: "camera")
                            }
                        } label: {
                            Label(
                                cameraLabel(camera, on: entry),
                                systemImage: entry.activeCamera == camera
                                    ? "stop.circle.fill" : "web.camera"
                            )
                        }
                    }
                }
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

    private func cameraLabel(_ camera: CameraDescription, on entry: DeviceEntry) -> String {
        var text = "\(camera.label) (\(entry.name))"
        if entry.activeCamera == camera, let description = entry.session?.cameraDescription {
            text += "\n\(description)"
        }
        return text
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
