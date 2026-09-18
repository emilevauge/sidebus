import ApplicationServices
import CoreGraphics
import Foundation

/// Autorisation Accessibilité, sans laquelle `CGEventPost` est ignoré en silence.
public enum AccessibilityPermission {

    public static func isTrusted() -> Bool {
        AXIsProcessTrusted()
    }

    /// Ouvre la demande système si l'autorisation manque. Elle ne prend effet qu'après
    /// relance de l'application : ne pas boucler sur `isTrusted()` dans la session
    /// courante, il ne passera jamais à vrai.
    @discardableResult
    public static func request() -> Bool {
        // La constante `kAXTrustedCheckOptionPrompt` est une variable globale mutable,
        // que Swift 6 refuse de lire depuis un contexte concurrent. Sa valeur est figée
        // dans l'API publique.
        let options = ["AXTrustedCheckOptionPrompt": true]
        return AXIsProcessTrustedWithOptions(options as CFDictionary)
    }
}

/// Injecte les touchers de la tablette comme des événements souris sur l'écran capturé.
public actor EventInjector {
    private let displayID: CGDirectDisplayID
    private var isPressed = false

    public init(displayID: CGDirectDisplayID) {
        self.displayID = displayID
    }

    /// Remappe des coordonnées normalisées sur les bornes de l'écran, en coordonnées
    /// globales. `CGDisplayBounds` et `CGEvent` partagent le même repère, origine en haut
    /// à gauche de l'écran principal.
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
            // Entre un appui et un relâchement, un déplacement est un glissement. Un
            // simple `mouseMoved` ne ferait pas glisser une fenêtre ni tracer une sélection.
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

    /// Relâche le bouton s'il est resté enfoncé, à la perte du lien par exemple.
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
