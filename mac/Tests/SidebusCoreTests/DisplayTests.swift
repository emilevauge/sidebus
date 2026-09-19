import CoreGraphics
import XCTest

@testable import SidebusCore

final class DisplayTests: XCTestCase {

    /// `CGGetActiveDisplayList` only lists awake displays: on a machine whose screen sleeps
    /// there are none. Tests that need one skip instead of failing for a reason unrelated
    /// to the code.
    private func requireAwakeDisplay() throws -> CGDirectDisplayID {
        let ids = try DisplayEnumerator.activeDisplayIDs()
        try XCTSkipIf(ids.isEmpty, "no awake display")
        return ids[0]
    }

    func testAtLeastOneActiveDisplay() throws {
        let id = try requireAwakeDisplay()
        XCTAssertTrue(DisplayEnumerator.isActive(id))
    }

    func testMissingDisplayIsInactive() {
        XCTAssertFalse(DisplayEnumerator.isActive(CGDirectDisplayID.max))
    }

    @MainActor
    func testFullEnumeration() throws {
        _ = try requireAwakeDisplay()
        let displays = try DisplayEnumerator.activeDisplays()
        XCTAssertEqual(displays.filter(\.isMain).count, 1)

        // Diagnostics for the phase 1 validation: DeskPad's display should show up here
        // while DeskPad runs.
        for display in displays {
            print("display \(display.id): \(display.menuLabel)")
        }
    }

    func testProviderReturnsTheTargetedIdentifier() async throws {
        let id = try requireAwakeDisplay()
        let provider = ExistingDisplayProvider(targetID: id)
        let acquired = try await provider.acquire()
        XCTAssertEqual(acquired, id)
        await provider.release()
    }

    func testProviderRefusesAMissingDisplay() async {
        let provider = ExistingDisplayProvider(targetID: .max)
        do {
            _ = try await provider.acquire()
            XCTFail("acquire() should have failed")
        } catch let error as DisplayError {
            guard case .displayUnavailable = error else {
                return XCTFail("unexpected error: \(error)")
            }
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testScaleAndLabel() {
        let hidpi = DisplayInfo(
            id: 1,
            name: "DeskPad Display",
            bounds: CGRect(x: 0, y: 0, width: 1920, height: 1080),
            pixelSize: CGSize(width: 3840, height: 2160),
            refreshRate: 60,
            isMain: false,
            isBuiltin: false
        )
        XCTAssertEqual(hidpi.scale, 2)
        XCTAssertEqual(hidpi.menuLabel, "DeskPad Display, 3840 × 2160 @2x")

        let lodpi = DisplayInfo(
            id: 2,
            name: "Moniteur",
            bounds: CGRect(x: 0, y: 0, width: 1920, height: 1080),
            pixelSize: CGSize(width: 1920, height: 1080),
            refreshRate: 60,
            isMain: true,
            isBuiltin: true
        )
        XCTAssertEqual(lodpi.scale, 1)
        XCTAssertEqual(lodpi.menuLabel, "Moniteur, 1920 × 1080 (principal)")
    }
}

final class StreamSizeTests: XCTestCase {

    func testDisplayLargerThanTheTablet() {
        // DeskPad en 2880x1800 vers une dalle 2400x1080 : c'est la hauteur qui contraint.
        let size = CaptureSession.streamSize(
            display: CGSize(width: 2880, height: 1800),
            device: CGSize(width: 2400, height: 1080)
        )
        XCTAssertEqual(size, CGSize(width: 1728, height: 1080))
    }

    func testNoUpscaling() {
        // A tablet larger than the captured display does not push the resolution up.
        let size = CaptureSession.streamSize(
            display: CGSize(width: 1440, height: 900),
            device: CGSize(width: 2560, height: 1600)
        )
        XCTAssertEqual(size, CGSize(width: 1440, height: 900))
    }

    func testEvenDimensions() {
        let size = CaptureSession.streamSize(
            display: CGSize(width: 1367, height: 769),
            device: CGSize(width: 1000, height: 1000)
        )
        XCTAssertEqual(size.width.truncatingRemainder(dividingBy: 2), 0)
        XCTAssertEqual(size.height.truncatingRemainder(dividingBy: 2), 0)
        XCTAssertLessThanOrEqual(size.width, 1000)
    }
}
