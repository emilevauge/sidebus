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

    var body: some Scene {
        Window("Sidebus Settings", id: "settings") {
            SettingsWindow(
                devices: devices,
                phone: .shared,
                displays: displays,
                permissions: permissions,
                updates: updates
            )
        }
        .windowResizability(.contentSize)

        // Custom label: MenuBarExtra then requires the
        // `MenuBarExtra { content } label: { ... }` shape.
        MenuBarExtra {
            MenuContent(devices: devices, phone: .shared, permissions: permissions, updates: updates)
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
        PhoneModel.shared.start()
    }

    /// `tel:` links, once Sidebus handles them: the dialer opens with the number typed
    /// in, and Return places the call.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme?.lowercased() == "tel" {
            let number = url.absoluteString
                .dropFirst("tel:".count)
                .split(separator: ";").first.map(String.init) ?? ""
            DialerPanel.shared.show(number: number.removingPercentEncoding ?? number)
        }
    }
}
