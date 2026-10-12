import AppKit
import SwiftUI

/// One line the call field suggests: a contact's number, or the typed number itself.
struct CallChoice: Equatable {
    let title: String
    let detail: String
    let number: String
    let name: String?
}

/// What the suggestion panel shows, shared with the call field that drives it.
@MainActor
@Observable
final class Suggestions {
    var choices: [CallChoice] = []
    var selection = 0
    var onPick: (Int) -> Void = { _ in }
}

/// The call field's suggestions, in a small panel beside the menu bar popover rather than
/// inside it, so the popover keeps its size while one types. The panel never takes the
/// keyboard: typing and the arrow keys stay with the field.
@MainActor
final class SuggestionPanel {
    static let shared = SuggestionPanel()

    let model = Suggestions()
    private var panel: NSPanel?
    private static let width: CGFloat = 300
    private static let gap: CGFloat = 8

    /// Shows the panel beside `window`, its top level with `anchor`, both in screen
    /// coordinates; hides it when there is nothing to suggest.
    func update(beside window: NSWindow?, anchor: NSRect) {
        guard let window, !model.choices.isEmpty else {
            hide()
            return
        }
        let panel = self.panel ?? makePanel()
        self.panel = panel
        let height = panel.contentView?.fittingSize.height ?? 200
        let screen = window.screen?.visibleFrame ?? .infinite
        var x = window.frame.maxX + Self.gap
        if x + Self.width > screen.maxX { x = window.frame.minX - Self.gap - Self.width }
        let y = max(screen.minY, anchor.maxY - height)
        panel.setFrame(NSRect(x: x, y: y, width: Self.width, height: height), display: true)
        if panel.parent == nil { window.addChildWindow(panel, ordered: .above) }
        panel.orderFront(nil)
    }

    func hide() {
        guard let panel else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 100),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.becomesKeyOnlyIfNeeded = true
        let host = NSHostingView(rootView: SuggestionList(model: model))
        host.sizingOptions = [.intrinsicContentSize]
        panel.contentView = host
        return panel
    }
}

private struct SuggestionList: View {
    let model: Suggestions

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(model.choices.enumerated()), id: \.offset) { index, choice in
                Button {
                    model.onPick(index)
                } label: {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(choice.title).lineLimit(1)
                        if !choice.detail.isEmpty {
                            Text(choice.detail).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(
                        index == model.selection ? Color.accentColor.opacity(0.25) : .clear,
                        in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(6)
        .frame(width: 300)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// Reports where a view sits on screen, and in which window.
struct ScreenFrameReader: NSViewRepresentable {
    let onChange: (NSWindow?, NSRect) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = ReportingView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        (view as? ReportingView)?.onChange = onChange
        (view as? ReportingView)?.report()
    }

    final class ReportingView: NSView {
        var onChange: (NSWindow?, NSRect) -> Void = { _, _ in }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            report()
        }

        override func layout() {
            super.layout()
            report()
        }

        func report() {
            guard let window else { return }
            onChange(window, window.convertToScreen(convert(bounds, to: nil)))
        }
    }
}
