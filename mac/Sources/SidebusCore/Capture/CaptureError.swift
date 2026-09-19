import CoreGraphics
import Foundation

public enum CaptureError: Error, CustomStringConvertible, Sendable {
    /// The Screen Recording permission is missing.
    case screenRecordingNotAuthorized

    /// The target display is not shareable through ScreenCaptureKit.
    case displayNotShareable(CGDirectDisplayID)

    /// ScreenCaptureKit stopped the stream.
    case streamStopped(String)

    public var description: String {
        switch self {
        case .screenRecordingNotAuthorized:
            return """
                Screen Recording permission refused. \
                System Settings > Privacy and Security > Screen Recording, \
                then restart Sidebus
                """
        case let .displayNotShareable(id):
            return "display \(id) is not shareable"
        case let .streamStopped(reason):
            return "capture stream stopped: \(reason)"
        }
    }
}
