import AppKit
import SidebusCore
import SwiftUI

/// What the panel and its footer share: whether the settings popover shows.
@MainActor
@Observable
final class PanelState {
    var showsSettings = false
}

/// The menu bar popover: calls on top, the devices below, a footer with the settings.
struct SidebusPanel: View {
    let devices: DeviceManager
    let phone: PhoneModel
    let dialer: DialerEntry
    let displays: DisplayMenuModel
    let permissions: PermissionsModel
    let updates: UpdateChecker
    @Bindable var state: PanelState

    static let width: CGFloat = 380

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let release = updates.available {
                UpdateBanner(version: release.version) { updates.install() }
                Divider()
            }

            // Only when calls can reach the Mac, or one is under way: the phone's row in the
            // devices says why not otherwise.
            if phone.callsAvailable || phone.isInCall {
                PhoneCard(phone: phone, entry: dialer)
                    .padding(14)
                Divider()
            }

            DeviceList(devices: devices, phone: phone)
                .padding(.vertical, 8)

            Divider()

            PanelFooter(state: state) {
                SettingsView(
                    devices: devices,
                    phone: phone,
                    displays: displays,
                    permissions: permissions,
                    updates: updates
                )
            }
        }
        .frame(width: Self.width)
        .fixedSize(horizontal: false, vertical: true)
        // Held against the top while the popover resizes around it, as in Calbar.
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

private struct UpdateBanner: View {
    let version: String
    let install: () -> Void

    var body: some View {
        HStack {
            Label("Sidebus \(version) is available", systemImage: "arrow.down.circle.fill")
                .foregroundStyle(.tint)
            Spacer()
            Button("Install", action: install).controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}

/// A small heading over a group of rows, as Calbar titles its sections.
struct PanelHeading: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .padding(.bottom, 2)
    }
}

/// The devices in reach, each with what it can do right now: carry calls, show the Mac's
/// screen. A click pairs, shares or stops sharing. The paired ones out of reach are in the
/// settings.
private struct DeviceList: View {
    let devices: DeviceManager
    let phone: PhoneModel

    /// The devices in reach, and the phone always: its row tells where calls stand.
    private var reachable: [DeviceEntry] {
        devices.entries.filter { $0.isOnline || $0.id == phone.phoneDeviceID }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            PanelHeading(title: "Devices")
            if let refusal = devices.lastRefusal {
                Text(refusal).font(.caption).foregroundStyle(.red)
                    .padding(.horizontal, 14)
            }
            if reachable.isEmpty {
                Text("None in reach. Plug a tablet in, or open Sidebus on it.")
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
            }
            ForEach(reachable) { entry in
                DeviceRow(entry: entry, phone: phone, isPhone: entry.id == phone.phoneDeviceID) {
                    devices.perform(entry)
                }
            }
        }
    }
}

private struct DeviceRow: View {
    let entry: DeviceEntry
    let phone: PhoneModel
    let isPhone: Bool
    let action: () -> Void
    @State private var hovered = false

    private var reachable: Bool { entry.isOnline || (isPhone && phone.callsAvailable) }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: isPhone ? "iphone" : "ipad.landscape")
                    .font(.system(size: 15))
                    .foregroundStyle(reachable ? .primary : .tertiary)
                    .frame(width: 30, height: 30)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 7, style: .continuous))

                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.name)
                        .foregroundStyle(reachable ? .primary : .secondary)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(isPhone && !phone.callsAvailable ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.secondary))
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                if isPhone {
                    if phone.callsAvailable, let over = phone.channelTransport {
                        Capability(symbol: over == .usb ? "cable.connector" : "wifi", active: true)
                            .help(over == .usb ? "Calls reach the Mac over USB" : "Calls reach the Mac over Wi-Fi")
                    }
                    Capability(symbol: "phone.fill", active: phone.callsAvailable)
                        .help(phone.summary)
                }
                Capability(symbol: "display", active: entry.isOnline, highlighted: entry.isSharing)
                    .help(screenHelp)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                hovered && entry.action != .none ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Not disabled when there is nothing to do: a disabled button greys its whole
        // label, and the phone's row read as offline while calls went through it.
        .allowsHitTesting(entry.action != .none)
        .onHover { hovered = $0 }
        .padding(.horizontal, 6)
    }

    private var subtitle: String {
        // For the phone, why calls stay on it comes first.
        if isPhone, !phone.callsAvailable { return phone.summary }
        if entry.isSharing { return entry.detail.map { "Sharing · \($0)" } ?? "Sharing" }
        if let session = entry.session, entry.isBusy { return session.detail ?? "Connecting…" }
        if entry.isOnline {
            return entry.isPaired ? "\(entry.transportLabel) · click to share the screen" : "\(entry.transportLabel) · click to pair"
        }
        if isPhone { return phone.summary }
        return entry.detail ?? "Offline"
    }

    private var screenHelp: String {
        if entry.isSharing { return "Showing the Mac's screen: click to stop" }
        if !entry.isOnline { return isPhone ? "Open Sidebus on the phone to share the screen" : "Not in sight" }
        return entry.isPaired ? "Click to share the Mac's screen" : "Click to pair"
    }
}

/// One thing a device can do: green when it can right now, accent while in use, greyed
/// otherwise.
private struct Capability: View {
    let symbol: String
    let active: Bool
    var highlighted = false

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 13))
            .foregroundStyle(highlighted ? AnyShapeStyle(Color.accentColor) : active ? AnyShapeStyle(Color.green) : AnyShapeStyle(.quaternary))
            .frame(width: 20)
    }
}

/// Bottom bar: settings and quit, with Calbar's fixed size buttons.
private struct PanelFooter<Settings: View>: View {
    @Bindable var state: PanelState
    @ViewBuilder let settings: () -> Settings

    var body: some View {
        HStack(spacing: 2) {
            IconButton("gearshape", tooltip: "Settings") {
                state.showsSettings.toggle()
            }
            .keyboardShortcut(",")
            .popover(isPresented: $state.showsSettings, arrowEdge: .trailing) {
                settings()
            }

            Spacer()

            IconButton("power", tooltip: "Quit Sidebus") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .frame(height: IconButton<IconGlyph>.size.height)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }
}
