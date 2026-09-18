import CoreGraphics
import Foundation

/// Description d'un écran actif, telle qu'affichée dans le sélecteur du menu bar.
public struct DisplayInfo: Identifiable, Hashable, Sendable {
    /// Identifiant CoreGraphics. Stable tant que l'écran reste branché, pas au delà.
    public let id: CGDirectDisplayID

    /// Nom lisible, celui que macOS affiche dans Réglages > Moniteurs.
    public let name: String

    /// Bornes en points, dans l'espace de coordonnées global de macOS.
    public let bounds: CGRect

    /// Taille du mode courant, en pixels.
    public let pixelSize: CGSize

    /// Fréquence de rafraîchissement en Hz. `0` si l'écran ne la publie pas.
    public let refreshRate: Double

    public let isMain: Bool
    public let isBuiltin: Bool

    public init(
        id: CGDirectDisplayID,
        name: String,
        bounds: CGRect,
        pixelSize: CGSize,
        refreshRate: Double,
        isMain: Bool,
        isBuiltin: Bool
    ) {
        self.id = id
        self.name = name
        self.bounds = bounds
        self.pixelSize = pixelSize
        self.refreshRate = refreshRate
        self.isMain = isMain
        self.isBuiltin = isBuiltin
    }

    /// Facteur d'échelle du mode courant : 2.0 en HiDPI, 1.0 sinon.
    public var scale: CGFloat {
        bounds.width > 0 ? pixelSize.width / bounds.width : 1
    }

    /// Libellé du sélecteur, par exemple `DeskPad Display, 1920 × 1080 @2x`.
    public var menuLabel: String {
        var label = "\(name), \(Int(pixelSize.width)) × \(Int(pixelSize.height))"
        if scale > 1.5 {
            label += " @\(Int(scale.rounded()))x"
        }
        if isMain {
            label += " (principal)"
        }
        return label
    }
}
