import XCTest

@testable import SidebusCore

final class BitrateControllerTests: XCTestCase {

    func testCutsSharplyOnHeavyDropping() {
        var controller = BitrateController(profile: .wifi)
        let start = controller.bitrate

        let applied = controller.apply(received: 80, dropped: 20)
        XCTAssertNotNil(applied)
        XCTAssertLessThan(controller.bitrate, start)
        XCTAssertEqual(controller.bitrate, Int(Double(start) * 0.6))
    }

    func testCutsGentlyOnAFewDrops() {
        var controller = BitrateController(profile: .wifi)
        let start = controller.bitrate
        controller.apply(received: 92, dropped: 8)
        XCTAssertEqual(controller.bitrate, Int(Double(start) * 0.85))
    }

    func testDoesNotClimbBackImmediately() {
        var controller = BitrateController(profile: .wifi)
        controller.apply(received: 50, dropped: 50)
        let low = controller.bitrate

        XCTAssertNil(controller.apply(received: 100, dropped: 0))
        XCTAssertNil(controller.apply(received: 100, dropped: 0))
        XCTAssertEqual(controller.bitrate, low, "climbed back too fast")

        XCTAssertNotNil(controller.apply(received: 100, dropped: 0))
        XCTAssertGreaterThan(controller.bitrate, low)
    }

    func testStaysWithinTheProfileBounds() {
        var controller = BitrateController(profile: .wifi)
        for _ in 0..<50 { controller.apply(received: 10, dropped: 90) }
        XCTAssertEqual(controller.bitrate, BitrateController.Profile.wifi.minimum)

        for _ in 0..<200 { controller.apply(received: 100, dropped: 0) }
        XCTAssertEqual(controller.bitrate, BitrateController.Profile.wifi.maximum)
    }

    func testUsbProfileIsMoreGenerousThanWifi() {
        XCTAssertGreaterThan(
            BitrateController.Profile.usb.start,
            BitrateController.Profile.wifi.start
        )
        XCTAssertGreaterThan(
            BitrateController.Profile.usb.maximum,
            BitrateController.Profile.wifi.maximum
        )
    }

    func testDropsTheFrameRateWhenTheFloorBitrateIsNotEnough() {
        var controller = BitrateController(profile: .wifi)
        for _ in 0..<50 { controller.apply(received: 10, dropped: 90) }

        XCTAssertEqual(
            controller.suggestedFrameRate(current: 60, received: 10, dropped: 90),
            30
        )
        // Once the tablet has calmed down, 60 is reachable again.
        XCTAssertEqual(
            controller.suggestedFrameRate(current: 30, received: 100, dropped: 0),
            60
        )
    }

    func testEmptyMeasurementIsIgnored() {
        var controller = BitrateController(profile: .usb)
        XCTAssertNil(controller.apply(received: 0, dropped: 0))
    }
}
