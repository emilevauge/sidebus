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
        Window("Réglages Sidebus", id: "settings") {
            SettingsWindow(devices: devices, displays: displays, permissions: permissions)
        }
        .windowResizability(.contentSize)

        MenuBarExtra("Sidebus", systemImage: menuBarSymbol) {
            MenuContent(devices: devices, permissions: permissions)
        }
    }

    /// L'icône dit d'un coup d'œil si quelque chose est diffusé.
    private var menuBarSymbol: String {
        devices.sharingCount > 0 ? "display.and.arrow.down" : "display"
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Pas d'icône dans le Dock, l'application ne vit que dans la barre de menus.
        // Le bundle porte aussi LSUIElement, ceci couvre le cas de `swift run`.
        NSApp.setActivationPolicy(.accessory)
    }
}
