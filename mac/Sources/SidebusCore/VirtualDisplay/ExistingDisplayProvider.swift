import CoreGraphics
import Foundation

/// Targets a display that already exists. Creates and destroys nothing.
///
/// In phase 1 the target is DeskPad's display, run as a development harness.
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
        // Nothing to do: the display is not ours.
    }
}
