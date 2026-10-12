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

/// The call field's suggestions, in a popover beside the field, styled as the settings
/// one, rather than inside the menu bar popover, which would resize on every key. The
/// keyboard goes back to the field once it shows: typing and the arrow keys stay there.
@MainActor
final class SuggestionPanel {
    static let shared = SuggestionPanel()

    let model = Suggestions()
    private lazy var popover: NSPopover = {
        let popover = NSPopover()
        // Closed with the field's popover, or when there is nothing left to suggest.
        popover.behavior = .applicationDefined
        popover.animates = false
        let host = NSHostingController(rootView: SuggestionList(model: model))
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host
        return popover
    }()

    /// Shows the suggestions beside `field`, or hides them when there are none.
    func update(beside field: NSView?) {
        guard let field, field.window?.isVisible == true, !model.choices.isEmpty else {
            hide()
            return
        }
        guard !popover.isShown else { return }
        popover.show(relativeTo: field.bounds, of: field, preferredEdge: .maxX)
        field.window?.makeKey()
    }

    func hide() {
        if popover.isShown { popover.close() }
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
        .frame(width: 280)
    }
}

/// Hands over the AppKit view behind a SwiftUI one, to anchor a popover on it.
struct AnchorView: NSViewRepresentable {
    let onView: (NSView) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { onView(view) }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {}
}
