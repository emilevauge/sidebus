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
        // Flipped, so the content hangs from the top: it is laid out at its new size at
        // once, and the popover's frame, animating, uncovers or covers its bottom. Stretched
        // to the popover instead, the content was recentred at every step and its top
        // moved.
        view = FlippedView()
        host.frame = view.bounds
        host.autoresizingMask = [.width]
        view.addSubview(host)
        host.onSizeChange = { [weak self] in self?.scheduleResize() }
    }

    private final class FlippedView: NSView {
        override var isFlipped: Bool { true }
    }

    /// The content at the size it asks for, against the top edge.
    private func pinHost(height: CGFloat) {
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
        pinHost(height: size.height)
    }

    /// Once per pass: SwiftUI may invalidate several times in a row.
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
        let size = host.intrinsicContentSize
        guard size.width > 0, size.height > 0, size != popover.contentSize else { return }
        resizeLog.info("resize \(popover.contentSize.height, privacy: .public) -> \(size.height, privacy: .public), shown \(popover.isShown, privacy: .public)")
        pinHost(height: size.height)
        guard popover.isShown else {
            popover.contentSize = size
            return
        }
        animate(popover, to: size)
    }

    private var animation: Timer?

    /// Steps the popover's size by hand, 60 times a second on the shared curve. Animated
    /// by AppKit, the content view took its final size at once while the window grew,
    /// and the window held it by its bottom: the top was cut off for the first frames.
    /// Set without animation at each step, window and content always match.
    private func animate(_ popover: NSPopover, to target: NSSize) {
        animation?.invalidate()
        let start = popover.contentSize
        let began = CACurrentMediaTime()
        popover.animates = false
        animation = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self, weak popover] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard let popover else {
                    self.animation?.invalidate()
                    return
                }
                let linear = min(1, (CACurrentMediaTime() - began) / Motion.duration)
                let progress = CGFloat(Self.ease(linear))
                popover.contentSize = NSSize(
                    width: start.width + (target.width - start.width) * progress,
                    height: start.height + (target.height - start.height) * progress
                )
                if linear >= 1 {
                    self.animation?.invalidate()
                    self.animation = nil
                    popover.animates = true
                }
            }
        }
    }

    /// Ease in and out, as `Motion.timing`.
    private static func ease(_ t: Double) -> Double {
        t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2
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
