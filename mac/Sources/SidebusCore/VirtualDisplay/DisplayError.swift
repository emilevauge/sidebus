import CoreGraphics
import Foundation

public enum DisplayError: Error, CustomStringConvertible, Sendable {
    /// `CGGetActiveDisplayList` failed.
    case enumerationFailed(CGError)

    /// The target display is no longer in the active display list.
    case displayUnavailable(CGDirectDisplayID)

    public var description: String {
        switch self {
        case let .enumerationFailed(code):
            return "cannot enumerate displays (CGError \(code.rawValue))"
        case let .displayUnavailable(id):
            return "display \(id) is no longer available"
        }
    }
}
