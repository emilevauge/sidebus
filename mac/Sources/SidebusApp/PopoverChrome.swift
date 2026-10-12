import AppKit
import SwiftUI
import os

private let resizeLog = Logger(subsystem: "app.sidebus", category: "popover")

// The popover chrome, taken from Calbar (same author) so that both menu bar apps look
// and move alike.

/// The one animation for changes that resize the popover. The popover frame is animated
/// by `PopoverHost` on the same curve and duration, so the panel and its content move
/// together.
enum Motion {
    static let duration: TimeInterval = 0.25
    static let resize = Animation.easeInOut(duration: duration)
    static var timing: CAMediaTimingFunction { CAMediaTimingFunction(name: .easeInEaseOut) }
}

/// Hosting view that reports each change of the size its content asks for.
private final class ReportingHostingView<Content: View>: NSHostingView<Content> {
    var onSizeChange: () -> Void = {}

    override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        onSizeChange()
    }

    /// SwiftUI updates its content in a layout pass without always invalidating the
    /// intrinsic size first.
    override func layout() {
        super.layout()
        onSizeChange()
    }
}

/// Content of the popover: hosts the SwiftUI view and resizes the popover to the size the
/// view asks for, animated with `Motion`. A hosting controller as content makes SwiftUI
/// resize the popover itself, at once, while the content still animates; here a plain
/// hosting view sits in a container with no constraints, so only this class sizes it.
final class PopoverHost<Content: View>: NSViewController {
    private let host: ReportingHostingView<Content>
    weak var popover: NSPopover?
    private var pendingResize = false

    init(rootView: Content) {
        host = ReportingHostingView(rootView: rootView)
        host.sizingOptions = [.intrinsicContentSize]
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func loadView() {
        // The content keeps its own height and hangs from the top of a flipped container.
        // Stretched to a taller popover, NSHostingView centred it: making room for the
        // keypad dropped everything by half the room, then the keypad's arrival raised it
        // again, animated.
        view = FlippedView()
        host.frame = view.bounds
        host.autoresizingMask = [.width]
        view.addSubview(host)
        host.onSizeChange = { [weak self] in self?.scheduleResize() }
    }

    private final class FlippedView: NSView {
        override var isFlipped: Bool { true }
    }

    /// The content at the height it asks for, against the top edge.
    private func pinHost() {
        let height = host.intrinsicContentSize.height
        guard height > 0, host.frame.height != height || host.frame.minY != 0 else { return }
        host.frame = NSRect(x: 0, y: 0, width: view.bounds.width, height: height)
    }

    /// Sets the popover to the content's size at once, before it shows.
    func fitPopover() {
        _ = view
        host.layoutSubtreeIfNeeded()
        let size = host.intrinsicContentSize
        guard let popover, size.width > 0, size.height > 0 else { return }
        resizeLog.info("fit \(popover.contentSize.height, privacy: .public) -> \(size.height, privacy: .public)")
        popover.contentSize = size
        pinHost()
    }

    /// Taller at once by `height`, without animation, ahead of content that will fill it.
    func grow(by height: CGFloat) {
        guard let popover, popover.isShown else { return }
        let animates = popover.animates
        popover.animates = false
        popover.contentSize.height += height
        popover.animates = animates
    }

    /// Once per pass, after SwiftUI's update: SwiftUI may invalidate several times in a
    /// row, and resizing within its update (an animated one, say the keypad opening)
    /// made it animate every view from positions offset by the change in height.
    private func scheduleResize() {
        guard !pendingResize else { return }
        pendingResize = true
        DispatchQueue.main.async { [weak self] in
            self?.pendingResize = false
            self?.resize()
        }
    }

    private func resize() {
        guard let popover else { return }
        pinHost()
        let size = host.intrinsicContentSize
        guard size.width > 0, size.height > 0, size != popover.contentSize else { return }
        resizeLog.info("resize \(popover.contentSize.height, privacy: .public) -> \(size.height, privacy: .public), shown \(popover.isShown, privacy: .public)")
        // One animation only, the content's: the popover takes its new size at once.
        // Animated too, it ran on its own clock, out of step with the content, and the
        // top of the panel slid while the two caught up.
        let animates = popover.animates
        popover.animates = false
        popover.contentSize = size
        popover.animates = animates
    }
}

/// Borderless icon button with a fixed frame, so every glyph of the footer gets the same
/// hit area.
struct IconButton<Label: View>: View {
    static var size: CGSize { CGSize(width: 28, height: 24) }

    let tooltip: String
    let action: () -> Void
    @ViewBuilder let label: () -> Label

    init(tooltip: String, action: @escaping () -> Void, @ViewBuilder label: @escaping () -> Label) {
        self.tooltip = tooltip
        self.action = action
        self.label = label
    }

    var body: some View {
        Button(action: action) {
            label()
                .frame(width: Self.size.width, height: Self.size.height)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(width: Self.size.width, height: Self.size.height)
        .help(tooltip)
    }
}

extension IconButton where Label == IconGlyph {
    init(_ systemName: String, tooltip: String, action: @escaping () -> Void) {
        self.init(tooltip: tooltip, action: action) { IconGlyph(systemName: systemName) }
    }
}

/// SF Symbol in the secondary style of the popover chrome.
struct IconGlyph: View {
    let systemName: String

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.secondary)
    }
}
