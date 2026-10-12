import AppKit
import Observation
import SidebusCore
import SwiftUI

@main
struct SidebusApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    // Everything lives in the menu bar popover, which AppDelegate runs: an NSStatusItem
    // and an NSPopover, as Calbar does, rather than MenuBarExtra, whose window style
    // cannot be opened from code (a phone link, a notification).
    var body: some Scene {
        Settings { EmptyView() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static private(set) var shared: AppDelegate!

    let devices = DeviceManager()
    let displays = DisplayMenuModel()
    let permissions = PermissionsModel()
    let updates = UpdateChecker()
    /// What is typed in the call search field, kept across openings.
    let dialer = DialerEntry()

    private var statusItem: NSStatusItem?
    private var popover: NSPopover?

    override init() {
        super.init()
        AppDelegate.shared = self
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // No Dock icon, the app lives in the menu bar alone. The bundle also carries
        // LSUIElement, this covers the `swift run` case.
        NSApp.setActivationPolicy(.accessory)
        setUpStatusItem()
        setUpPopover()
        PhoneModel.shared.start()
    }

    /// `tel:` links, once Sidebus handles them: the panel opens with the number typed in,
    /// and Return places the call.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme?.lowercased() == "tel" {
            let number = url.absoluteString
                .dropFirst("tel:".count)
                .split(separator: ";").first.map(String.init) ?? ""
            showPanel(number: number.removingPercentEncoding ?? number)
        }
    }

    // MARK: - Menu bar

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.action = #selector(statusItemClicked)
        item.button?.target = self
        item.button?.setAccessibilityLabel("Sidebus")
        statusItem = item
        followSharing()
    }

    /// The icon says at a glance whether anything is streaming.
    private func followSharing() {
        withObservationTracking {
            statusItem?.button?.image = MenuBarIcon.forSharing(devices.sharingCount > 0)
        } onChange: {
            Task { @MainActor in self.followSharing() }
        }
    }

    private func setUpPopover() {
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        let host = PopoverHost(rootView: SidebusPanel(
            devices: devices,
            phone: .shared,
            dialer: dialer,
            displays: displays,
            permissions: permissions,
            updates: updates
        ))
        host.popover = popover
        popover.contentViewController = host
        self.popover = popover
    }

    @objc private func statusItemClicked() {
        if popover?.isShown == true {
            popover?.performClose(nil)
        } else {
            showPanel()
        }
    }

    /// Opens the panel, with `number` typed in the call field when a link brought one.
    func showPanel(number: String? = nil) {
        if let number { dialer.text = number }
        guard let popover, let button = statusItem?.button else { return }
        (popover.contentViewController as? PopoverHost<SidebusPanel>)?.fitPopover()
        NSApp.activate(ignoringOtherApps: true)
        if !popover.isShown {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
        popover.contentViewController?.view.window?.makeKey()
    }
}
