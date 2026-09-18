import CoreGraphics
import Foundation

public enum DisplayError: Error, CustomStringConvertible, Sendable {
    /// `CGGetActiveDisplayList` a échoué.
    case enumerationFailed(CGError)

    /// L'écran visé n'est plus dans la liste des écrans actifs.
    case displayUnavailable(CGDirectDisplayID)

    public var description: String {
        switch self {
        case let .enumerationFailed(code):
            return "énumération des écrans impossible (CGError \(code.rawValue))"
        case let .displayUnavailable(id):
            return "l'écran \(id) n'est plus disponible"
        }
    }
}
