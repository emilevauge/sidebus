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

        let cameras = devices.sessions.filter { !$0.cameras.isEmpty }
        if !cameras.isEmpty {
            Divider()

            Section("Cameras") {
                ForEach(cameras, id: \.key) { session in
                    ForEach(session.cameras, id: \.id) { camera in
                        Button {
                            if session.activeCamera == camera {
                                session.stopCamera()
                            } else {
                                session.startCamera(camera)
                                openWindow(id: "camera")
                            }
                        } label: {
                            Label(
                                cameraLabel(camera, on: session),
                                systemImage: session.activeCamera == camera
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

    private func cameraLabel(_ camera: CameraDescription, on session: DeviceSession) -> String {
        var text = camera.label
        if let name = session.deviceName { text += " (\(name))" }
        if session.activeCamera == camera, let description = session.cameraDescription {
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
