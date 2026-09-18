import CoreGraphics
import Foundation

/// Source de l'écran que Sidebus capture.
///
/// Tout le reste du code passe par cette abstraction et ne sait jamais d'où vient
/// l'écran. Deux implémentations :
///
/// - `ExistingDisplayProvider` : cible un écran déjà présent, physique ou créé par
///   DeskPad. Utilisée en phase 1, conservée ensuite comme mode dégradé si l'API privée
///   `CGVirtualDisplay` casse sur une version de macOS.
/// - `CGVirtualDisplayProvider` : crée l'écran lui même, phase 7.
public protocol VirtualDisplayProvider: Sendable {
    /// Rend un écran disponible et renvoie son identifiant.
    func acquire() async throws -> CGDirectDisplayID

    /// Libère l'écran. Sans effet si rien n'a été acquis.
    func release() async
}
