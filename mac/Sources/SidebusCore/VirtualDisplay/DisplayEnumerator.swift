import AppKit
import CoreGraphics
import Foundation

/// Liste les écrans actifs vus par macOS, physiques ou virtuels.
///
/// En phase 1 l'écran virtuel vient de DeskPad, lancé à côté. Pour Sidebus c'est un
/// écran comme un autre : rien ici ne distingue un écran virtuel d'un moniteur branché.
public enum DisplayEnumerator {

    /// Identifiants des écrans actifs. Pur CoreGraphics, appelable depuis n'importe quel
    /// contexte.
    ///
    /// « Actif » au sens de CoreGraphics veut dire connecté **et éveillé** : quand
    /// l'écran du Mac dort, la liste est vide. Ce n'est pas une erreur.
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

    /// Taille du mode courant d'un écran, en pixels.
    public static func pixelSize(of id: CGDirectDisplayID) -> CGSize {
        guard let mode = CGDisplayCopyDisplayMode(id) else { return CGDisplayBounds(id).size }
        return CGSize(width: mode.pixelWidth, height: mode.pixelHeight)
    }

    /// `true` si l'écran est toujours actif.
    public static func isActive(_ id: CGDirectDisplayID) -> Bool {
        ((try? activeDisplayIDs()) ?? []).contains(id)
    }

    /// Écrans actifs avec leurs noms et leurs modes.
    ///
    /// Isolé sur le main actor parce que le nom lisible vient de `NSScreen`, seule API
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
                name: names[id] ?? "Écran \(id)",
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
