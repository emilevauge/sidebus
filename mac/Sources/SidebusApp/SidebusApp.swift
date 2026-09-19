import AppKit
import SidebusCore
import SwiftUI

@main
struct SidebusApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var displays = DisplayMenuModel()
    @State private var devices = DeviceManager()
    @State private var permissions = PermissionsModel()
    @State private var updates = UpdateChecker()
    @State private var cameraExtension = CameraExtensionInstaller()

    var body: some Scene {
        Window("Sidebus Settings", id: "settings") {
            SettingsWindow(
                devices: devices,
                displays: displays,
                permissions: permissions,
                updates: updates,
                cameraExtension: cameraExtension
            )
        }
        .windowResizability(.contentSize)

        Window("Camera", id: "camera") {
            CameraWindow(devices: devices)
        }

        // Custom label: MenuBarExtra then requires the
        // `MenuBarExtra { content } label: { ... }` shape.
        MenuBarExtra {
            MenuContent(devices: devices, permissions: permissions, updates: updates)
        } label: {
            // The icon says at a glance whether anything is streaming.
            Image(nsImage: MenuBarIcon.forSharing(devices.sharingCount > 0))
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // No Dock icon, the app lives in the menu bar alone. The bundle also carries
        // LSUIElement, this covers the `swift run` case.
        NSApp.setActivationPolicy(.accessory)
    }
}
