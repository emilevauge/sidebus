import CoreGraphics
import Foundation

public enum CaptureError: Error, CustomStringConvertible, Sendable {
    /// L'autorisation Enregistrement de l'écran manque.
    case screenRecordingNotAuthorized

    /// L'écran visé n'est pas partageable par ScreenCaptureKit.
    case displayNotShareable(CGDirectDisplayID)

    /// ScreenCaptureKit a arrêté le flux.
    case streamStopped(String)

    public var description: String {
        switch self {
        case .screenRecordingNotAuthorized:
            return """
                autorisation Enregistrement de l'écran refusée. \
                Réglages > Confidentialité et sécurité > Enregistrement de l'écran, \
                puis relancer Sidebus
                """
        case let .displayNotShareable(id):
            return "l'écran \(id) n'est pas partageable"
        case let .streamStopped(reason):
            return "flux de capture arrêté : \(reason)"
        }
    }
}
