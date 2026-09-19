import CoreGraphics
import Foundation

/// Source of the display Sidebus captures.
///
/// The rest of the code goes through this abstraction and never learns where the display
/// came from. Two implementations:
///
/// - `ExistingDisplayProvider`: targets a display that already exists, physical or made
///   by DeskPad. Used in phase 1, kept afterwards as the fallback when the private API
///   `CGVirtualDisplay` casse sur une version de macOS.
/// - `CGVirtualDisplayProvider`: creates the display itself, phase 7.
public protocol VirtualDisplayProvider: Sendable {
    /// Makes a display available and returns its identifier.
    func acquire() async throws -> CGDirectDisplayID

    /// Releases the display. A no-op when nothing was acquired.
    func release() async
}
