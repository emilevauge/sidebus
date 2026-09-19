import CoreGraphics
import XCTest

@testable import SidebusCore

final class EventInjectorTests: XCTestCase {

    /// A secondary display placed to the right of the main one: global coordinates do not
    /// start at zero, and that is the case that breaks when the origin is forgotten.
    private let bounds = CGRect(x: 5120, y: 0, width: 2880, height: 1800)

    func testCornersAndCentre() {
        XCTAssertEqual(
            EventInjector.point(x: 0, y: 0, in: bounds),
            CGPoint(x: 5120, y: 0)
        )
        XCTAssertEqual(
            EventInjector.point(x: 1, y: 1, in: bounds),
            CGPoint(x: 8000, y: 1800)
        )
        XCTAssertEqual(
            EventInjector.point(x: 0.5, y: 0.5, in: bounds),
            CGPoint(x: 6560, y: 900)
        )
    }

    func testOriginAtTopLeft() {
        // y = 0.25 doit tomber dans le quart haut, pas dans le quart bas.
        let point = EventInjector.point(x: 0, y: 0.25, in: bounds)
        XCTAssertEqual(point.y, 450)
    }

    func testOutOfRangeCoordinatesAreClamped() {
        XCTAssertEqual(
            EventInjector.point(x: -1, y: 2, in: bounds),
            CGPoint(x: 5120, y: 1800)
        )
    }
}
