import AppKit
import SidebusCore
import SwiftUI

/// The menu bar popover: the phone, the screens, and a footer with the settings.
struct SidebusPanel: View {
    let devices: DeviceManager
    let phone: PhoneModel
    let dialer: DialerEntry
    let displays: DisplayMenuModel
    let permissions: PermissionsModel
    let updates: UpdateChecker

    static let width: CGFloat = 380

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                if let release = updates.available {
                    Button {
                        updates.install()
                    } label: {
                        Label("Sidebus \(release.version) is available, install it", systemImage: "arrow.down.circle.fill")
                    }
                    .buttonStyle(.link)
                }

                if phone.phoneName != nil || phone.isInCall {
                    PanelSection(title: "Phone") {
                        PhoneCard(phone: phone, entry: dialer)
                    }
                }

                PanelSection(title: "Screens") {
                    ScreenList(devices: devices)
                }
            }
            .padding(14)

            Divider()

            PanelFooter {
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
    }
}

/// A titled card, as the grouped settings draw their sections.
struct PanelSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 4)
            content()
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }
}

/// The screens in sight and the paired ones: a click pairs, shares or stops.
private struct ScreenList: View {
    let devices: DeviceManager

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let refusal = devices.lastRefusal {
                Text(refusal).font(.caption).foregroundStyle(.red)
                    .padding(.bottom, 6)
            }
            if devices.entries.isEmpty {
                Text(devices.summary).foregroundStyle(.secondary)
            }
            ForEach(Array(devices.entries.enumerated()), id: \.element.id) { index, entry in
                if index > 0 { Divider().padding(.vertical, 6) }
                Button {
                    devices.perform(entry)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: entry.symbol)
                            .frame(width: 22)
                            .foregroundStyle(entry.isOnline ? .primary : .secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.name).foregroundStyle(entry.isOnline ? .primary : .secondary)
                            if let subtitle = subtitle(entry) {
                                Text(subtitle).font(.caption).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(entry.action == .none)
            }
        }
    }

    private func subtitle(_ entry: DeviceEntry) -> String? {
        var parts: [String] = []
        if entry.isOnline { parts.append(entry.transportLabel) }
        if let detail = entry.detail, !detail.isEmpty { parts.append(detail) }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }
}

/// Bottom bar: settings and quit, with Calbar's fixed size buttons.
private struct PanelFooter<Settings: View>: View {
    @ViewBuilder let settings: () -> Settings
    @State private var showingSettings = false

    var body: some View {
        HStack(spacing: 2) {
            IconButton("gearshape", tooltip: "Settings") {
                showingSettings.toggle()
            }
            .keyboardShortcut(",")
            .popover(isPresented: $showingSettings, arrowEdge: .trailing) {
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
