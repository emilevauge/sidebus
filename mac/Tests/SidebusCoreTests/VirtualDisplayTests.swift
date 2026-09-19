import CoreGraphics
import XCTest

@testable import SidebusCore

final class CGVirtualDisplayProviderTests: XCTestCase {

    func testPhysicalSizeYieldsTheRequestedDensity() {
        let configuration = CGVirtualDisplayProvider.Configuration(
            width: 2560,
            height: 1600,
            density: 320
        )
        // 2560 px at 320 dpi = 8 inches = 203.2 mm.
        XCTAssertEqual(configuration.sizeInMillimeters.width, 203.2, accuracy: 0.1)
        XCTAssertEqual(configuration.sizeInMillimeters.height, 127.0, accuracy: 0.1)
    }

    func testHiDPIModeOnADensePanel() {
        let dense = CGVirtualDisplayProvider.Configuration(width: 2560, height: 1600, density: 320)
        XCTAssertEqual(dense.pointSize.width, 1280)
        XCTAssertEqual(dense.pointSize.height, 800)

        // A low density panel: no HiDPI, the interface would be enormous otherwise.
        let coarse = CGVirtualDisplayProvider.Configuration(width: 1920, height: 1200, density: 160)
        XCTAssertEqual(coarse.pointSize.width, 1920)
    }

    func testPrivateApiIsPresent() {
        // If this test fails on a future macOS release, that is the signal the
        // bascule sur ExistingDisplayProvider devient le chemin normal.
        XCTAssertTrue(
            CGVirtualDisplayProvider.isSupported,
            "les classes CGVirtualDisplay ont disparu de CoreGraphics"
        )
    }

    func testCreatesAndRemovesARealDisplay() async throws {
        try XCTSkipUnless(
            CGVirtualDisplayProvider.isSupported,
            "private API missing"
        )

        // macOS refuses a second virtual display: when the app is already running and holds
        // its own, this test has no room to run.
        let existing = await MainActor.run { (try? DisplayEnumerator.activeDisplays()) ?? [] }
        try XCTSkipIf(
            existing.contains { $0.name.contains("Sidebus") },
            "a Sidebus virtual display is already active, the app is running"
        )

        let before = try DisplayEnumerator.activeDisplayIDs()
        try XCTSkipIf(before.isEmpty, "no awake display")

        let provider = CGVirtualDisplayProvider(
            configuration: .init(width: 2560, height: 1600, density: 320, name: "Sidebus test")
        )

        let id = try await provider.acquire()
        XCTAssertNotEqual(id, 0)

        // The display must show up in the active display list.
        try await Task.sleep(for: .milliseconds(500))
        let during = try DisplayEnumerator.activeDisplayIDs()
        XCTAssertTrue(during.contains(id), "the virtual display is not active")
        XCTAssertEqual(during.count, before.count + 1)

        // The HiDPI mode must have been selected: macOS otherwise keeps 1x, which
        // donne une interface minuscule sur une dalle dense.
        let bounds = CGDisplayBounds(id)
        XCTAssertEqual(bounds.width, 1280, "HiDPI mode expected, so 1280 points")
        XCTAssertEqual(bounds.height, 800)

        // `CGDisplayCopyDisplayMode` returns nil on a virtual display whose mode was set with
        // `.forSession`: the setting is not written into the permanent configuration, and
        // the API only reads that one. The bounds above already say the 2x mode is active,
        // so the mode is only demanded when it is exposed.
        if let mode = CGDisplayCopyDisplayMode(id) {
            XCTAssertEqual(mode.pixelWidth, 2560)
            XCTAssertEqual(mode.pixelHeight, 1600)
        }

        await provider.release()
        try await Task.sleep(for: .milliseconds(500))
        let after = try DisplayEnumerator.activeDisplayIDs()
        XCTAssertFalse(after.contains(id), "the virtual display was not removed")
        XCTAssertEqual(after.count, before.count)
    }
}
