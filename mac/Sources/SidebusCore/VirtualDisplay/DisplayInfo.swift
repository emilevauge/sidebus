import CoreGraphics
import Foundation

/// Description of an active display, as shown in the settings picker.
public struct DisplayInfo: Identifiable, Hashable, Sendable {
    /// CoreGraphics identifier. Stable while the display stays attached, no longer.
    public let id: CGDirectDisplayID

    /// Readable name, the one macOS shows under System Settings > Displays.
    public let name: String

    /// Bounds in points, in the global macOS coordinate space.
    public let bounds: CGRect

    /// Taille du mode courant, en pixels.
    public let pixelSize: CGSize

    /// Refresh rate in Hz. `0` when the display does not publish it.
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

    /// Scale factor of the current mode: 2.0 in HiDPI, 1.0 otherwise.
    public var scale: CGFloat {
        bounds.width > 0 ? pixelSize.width / bounds.width : 1
    }

    /// Picker label, for example `DeskPad Display, 1920 × 1080 @2x`.
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
