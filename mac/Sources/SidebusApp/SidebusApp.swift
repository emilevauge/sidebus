import AppKit
import SidebusCore
import SwiftUI

@main
struct SidebusApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var displays = DisplayMenuModel()
    @State private var devices = DeviceManager()
    @State private var permissions = PermissionsModel()

    var body: some Scene {
        Window("Sidebus Settings", id: "settings") {
            SettingsWindow(devices: devices, displays: displays, permissions: permissions)
        }
        .windowResizability(.contentSize)

        // Custom label: MenuBarExtra then requires the
        // `MenuBarExtra { content } label: { ... }` shape.
        MenuBarExtra {
            MenuContent(devices: devices, permissions: permissions)
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
