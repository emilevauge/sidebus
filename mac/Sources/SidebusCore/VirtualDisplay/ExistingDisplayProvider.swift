import CoreGraphics
import Foundation

/// Cible un écran qui existe déjà. Ne crée ni ne détruit rien.
///
/// En phase 1 l'écran visé est celui de DeskPad, lancé comme harnais de développement.
public actor ExistingDisplayProvider: VirtualDisplayProvider {
    public let targetID: CGDirectDisplayID

    public init(targetID: CGDirectDisplayID) {
        self.targetID = targetID
    }

    public func acquire() throws -> CGDirectDisplayID {
        guard DisplayEnumerator.isActive(targetID) else {
            throw DisplayError.displayUnavailable(targetID)
        }
        return targetID
    }

    public func release() {
        // Rien à faire : l'écran ne nous appartient pas.
    }
}
