import AppKit
import SidebusCore
import SwiftUI

@main
struct SidebusApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = DisplayMenuModel()
    @State private var connection = ConnectionModel()
    @State private var permissions = PermissionsModel()

    var body: some Scene {
        Window("Autorisations Sidebus", id: "permissions") {
            PermissionsView(model: permissions)
        }
        .windowResizability(.contentSize)

        MenuBarExtra("Sidebus", systemImage: "display") {
            MenuContent(model: model, connection: connection, permissions: permissions)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Pas d'icône dans le Dock, l'application ne vit que dans la barre de menus.
        // Le bundle porte aussi LSUIElement, ceci couvre le cas de `swift run`.
        NSApp.setActivationPolicy(.accessory)
    }
}
