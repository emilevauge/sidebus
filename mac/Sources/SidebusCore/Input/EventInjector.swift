import ApplicationServices
import CoreGraphics
import Foundation

/// Accessibility permission, without which `CGEventPost` is silently ignored.
public enum AccessibilityPermission {

    public static func isTrusted() -> Bool {
        AXIsProcessTrusted()
    }

    /// Opens the system prompt when the permission is missing. It only takes effect after
    /// the app restarts: do not poll `isTrusted()` in the current session, it will never
    /// turn true.
    @discardableResult
    public static func request() -> Bool {
        // `kAXTrustedCheckOptionPrompt` is a mutable global that Swift 6 refuses to read
        // from a concurrent context. Its value is frozen in the public API.
        let options = ["AXTrustedCheckOptionPrompt": true]
        return AXIsProcessTrustedWithOptions(options as CFDictionary)
    }
}

/// Injects the tablet's touches as mouse events on the captured display.
public actor EventInjector {
    private let displayID: CGDirectDisplayID
    private var isPressed = false

    public init(displayID: CGDirectDisplayID) {
        self.displayID = displayID
    }

    /// Maps normalised coordinates onto the display bounds, in global coordinates.
    /// `CGDisplayBounds` and `CGEvent` share the same frame, with the origin at the top
    /// left of the main display.
    public static func point(
        x: Float,
        y: Float,
        in bounds: CGRect
    ) -> CGPoint {
        CGPoint(
            x: bounds.minX + CGFloat(min(max(x, 0), 1)) * bounds.width,
            y: bounds.minY + CGFloat(min(max(y, 0), 1)) * bounds.height
        )
    }

    public func inject(kind: InputEventKind, x: Float, y: Float, button: MouseButton) {
        let bounds = CGDisplayBounds(displayID)
        guard !bounds.isEmpty else { return }
        let position = Self.point(x: x, y: y, in: bounds)

        let type: CGEventType
        switch (kind, button) {
        case (.down, .left): type = .leftMouseDown
        case (.up, .left): type = .leftMouseUp
        case (.down, .right): type = .rightMouseDown
        case (.up, .right): type = .rightMouseUp
        case (.down, .middle), (.up, .middle): type = .otherMouseDown
        case (.move, _):
            // Between a press and a release, a move is a drag. A plain `mouseMoved` would
            // neither drag a window nor draw a selection.
            type = isPressed ? .leftMouseDragged : .mouseMoved
        }

        switch kind {
        case .down: isPressed = true
        case .up: isPressed = false
        case .move: break
        }

        let cgButton: CGMouseButton
        switch button {
        case .left: cgButton = .left
        case .right: cgButton = .right
        case .middle: cgButton = .center
        }

        guard let event = CGEvent(
            mouseEventSource: nil,
            mouseType: type,
            mouseCursorPosition: position,
            mouseButton: cgButton
        ) else { return }

        // Sans ce champ, un appui suivi d'un relâchement ne compte pas comme un clic.
        if kind != .move {
            event.setIntegerValueField(.mouseEventClickState, value: 1)
        }

        event.post(tap: .cghidEventTap)
    }

    /// Releases the button if it stayed down, on link loss for instance.
    public func releaseIfNeeded() {
        guard isPressed else { return }
        let bounds = CGDisplayBounds(displayID)
        let position = CGPoint(x: bounds.midX, y: bounds.midY)
        if let event = CGEvent(
            mouseEventSource: nil,
            mouseType: .leftMouseUp,
            mouseCursorPosition: position,
            mouseButton: .left
        ) {
            event.post(tap: .cghidEventTap)
        }
        isPressed = false
    }
}
