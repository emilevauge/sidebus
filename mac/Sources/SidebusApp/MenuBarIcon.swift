import AppKit

/// The two menu bar templates, loaded once from the module's resource bundle.
///
/// They are vector PDFs marked `isTemplate`: macOS redraws them in black or white
/// depending on the theme and on the menu bar's colour, and keeps them crisp at every
/// screen scale.
enum MenuBarIcon {
    /// At rest: the windscreen panel is hollow.
    static let atRest = load("MenuBar")
    /// Sharing in progress: the panel is filled, and the difference reads at 18 points.
    static let active = load("MenuBarActive")

    static func forSharing(_ isSharing: Bool) -> NSImage {
        isSharing ? active : atRest
    }

    private static func load(_ name: String) -> NSImage {
        let image: NSImage
        if let url = Bundle.module.url(forResource: name, withExtension: "pdf"),
           let pdf = NSImage(contentsOf: url) {
            image = pdf
        } else {
            // Fall back to a system symbol: an approximate icon beats an empty menu bar when
            // the resource is missing.
            image = NSImage(systemSymbolName: "display", accessibilityDescription: "Sidebus")
                ?? NSImage()
        }
        image.size = NSSize(width: 18, height: 18)
        image.isTemplate = true
        return image
    }
}
