import XCTest

@testable import SidebusCore

final class SidebusTests: XCTestCase {
    func testConstantesDuProtocole() {
        XCTAssertEqual(Sidebus.protocolVersion, 1)
        XCTAssertEqual(Sidebus.port, 27183)
        XCTAssertEqual(Sidebus.serviceType, "_sidebus._tcp")
    }
}
