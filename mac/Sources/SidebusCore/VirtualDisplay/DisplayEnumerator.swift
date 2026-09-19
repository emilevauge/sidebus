import AppKit
import CoreGraphics
import Foundation

/// Lists the active displays macOS sees, physical or virtual.
///
/// In phase 1 the virtual display came from DeskPad, run alongside. To Sidebus it is a
/// display like any other: nothing here tells a virtual one from an attached monitor.
public enum DisplayEnumerator {

    /// Identifiers of the active displays. Pure CoreGraphics, callable from any
    /// contexte.
    ///
    /// "Active" in the CoreGraphics sense means attached **and awake**: when the Mac's
    /// screen sleeps the list is empty. That is not an error.
    public static func activeDisplayIDs() throws -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        var status = CGGetActiveDisplayList(0, nil, &count)
        guard status == .success else { throw DisplayError.enumerationFailed(status) }
        guard count > 0 else { return [] }

        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        status = CGGetActiveDisplayList(count, &ids, &count)
        guard status == .success else { throw DisplayError.enumerationFailed(status) }

        return Array(ids.prefix(Int(count)))
    }

    /// Size of a display's current mode, in pixels.
    public static func pixelSize(of id: CGDirectDisplayID) -> CGSize {
        guard let mode = CGDisplayCopyDisplayMode(id) else { return CGDisplayBounds(id).size }
        return CGSize(width: mode.pixelWidth, height: mode.pixelHeight)
    }

    /// `true` when the display is still active.
    public static func isActive(_ id: CGDirectDisplayID) -> Bool {
        ((try? activeDisplayIDs()) ?? []).contains(id)
    }

    /// Active displays with their names and modes.
    ///
    /// Isolated on the main actor because the readable name comes from `NSScreen`, the only
    /// publique qui le donne. Le reste du pipeline ne manipule qu'un `CGDirectDisplayID`.
    @MainActor
    public static func activeDisplays() throws -> [DisplayInfo] {
        let names = screenNamesByDisplayID()
        return try activeDisplayIDs().map { id in
            let mode = CGDisplayCopyDisplayMode(id)
            let bounds = CGDisplayBounds(id)
            let pixelSize = mode.map { CGSize(width: $0.pixelWidth, height: $0.pixelHeight) }
                ?? bounds.size
            return DisplayInfo(
                id: id,
                name: names[id] ?? "Display \(id)",
                bounds: bounds,
                pixelSize: pixelSize,
                refreshRate: mode?.refreshRate ?? 0,
                isMain: CGDisplayIsMain(id) != 0,
                isBuiltin: CGDisplayIsBuiltin(id) != 0
            )
        }
    }

    @MainActor
    private static func screenNamesByDisplayID() -> [CGDirectDisplayID: String] {
        var names: [CGDirectDisplayID: String] = [:]
        for screen in NSScreen.screens {
            guard let number = screen.deviceDescription[.init("NSScreenNumber")] as? NSNumber else {
                continue
            }
            names[CGDirectDisplayID(number.uint32Value)] = screen.localizedName
        }
        return names
    }
}
