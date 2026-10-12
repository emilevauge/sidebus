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
    let panelState = PanelState()

    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var outsideClicks: Any?
    private var escapeKey: Any?

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

        // Development hook: opens the panel, or its settings, at launch, to look at them.
        switch ProcessInfo.processInfo.environment["SIDEBUS_OPEN"] {
        case "panel":
            showPanel()
        case "settings":
            showPanel()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.panelState.showsSettings = true }
        default:
            break
        }
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
        // Closed by hand, on clicks outside Sidebus and on Esc: a transient popover also
        // closes on a click in the suggestion panel beside it.
        popover.behavior = .applicationDefined
        popover.animates = true
        let host = PopoverHost(rootView: SidebusPanel(
            devices: devices,
            phone: .shared,
            dialer: dialer,
            displays: displays,
            permissions: permissions,
            updates: updates,
            state: panelState
        ))
        host.popover = popover
        popover.contentViewController = host
        host.fitPopover()
        self.popover = popover
        NotificationCenter.default.addObserver(
            forName: NSPopover.didCloseNotification, object: popover, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.openedForCall = false
                SuggestionPanel.shared.hide()
                self?.stopWatchingOutside()
            }
        }
    }

    private func watchOutside() {
        stopWatchingOutside()
        outsideClicks = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.popover?.performClose(nil) }
        }
        escapeKey = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // Esc in the call field first clears it; once empty, it closes the panel.
            guard event.keyCode == 53,
                  AppDelegate.shared.dialer.text.isEmpty,
                  self?.popover?.isShown == true else { return event }
            self?.popover?.performClose(nil)
            return nil
        }
    }

    private func stopWatchingOutside() {
        if let outsideClicks { NSEvent.removeMonitor(outsideClicks) }
        if let escapeKey { NSEvent.removeMonitor(escapeKey) }
        outsideClicks = nil
        escapeKey = nil
    }

    @objc private func statusItemClicked() {
        if popover?.isShown == true {
            popover?.performClose(nil)
        } else {
            showPanel()
        }
    }

    /// Opens the panel, with `number` typed in the call field when a link brought one.
    ///
    /// The hop to the next pass lets SwiftUI apply what changed while the popover was
    /// closed, a call that started say, before it is measured: shown at once, it opened at
    /// its old size and jumped.
    ///
    /// `activate` false shows it without taking the keyboard from the app in use, for a
    /// call that starts ringing.
    func showPanel(number: String? = nil, activate: Bool = true) {
        if let number { dialer.text = number }
        DispatchQueue.main.async { [weak self] in
            guard let self, let popover, let button = statusItem?.button else { return }
            (popover.contentViewController as? PopoverHost<SidebusPanel>)?.fitPopover()
            if activate { NSApp.activate(ignoringOtherApps: true) }
            if !popover.isShown {
                popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
                watchOutside()
            }
            if activate { popover.contentViewController?.view.window?.makeKey() }
        }
    }

    /// Makes room at the bottom of the panel, at once, for content about to appear there.
    func growPanel(by height: CGFloat) {
        (popover?.contentViewController as? PopoverHost<SidebusPanel>)?.grow(by: height)
    }

    /// Opens the panel for a ringing call, and closes it when the call ends if it was
    /// opened that way and left alone.
    func showPanelForCall() {
        guard popover?.isShown != true else { return }
        openedForCall = true
        showPanel(activate: false)
    }

    func callEnded() {
        guard openedForCall else { return }
        openedForCall = false
        popover?.performClose(nil)
    }

    private var openedForCall = false
}
