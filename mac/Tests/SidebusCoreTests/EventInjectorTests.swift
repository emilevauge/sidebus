import CoreGraphics
import XCTest

@testable import SidebusCore

final class EventInjectorTests: XCTestCase {

    /// Écran secondaire posé à droite du principal : les coordonnées globales ne
    /// commencent pas à zéro, c'est le cas qui casse si on oublie l'origine.
    private let bounds = CGRect(x: 5120, y: 0, width: 2880, height: 1800)

    func testCoinsEtCentre() {
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

    func testOrigineEnHautAGauche() {
        // y = 0.25 doit tomber dans le quart haut, pas dans le quart bas.
        let point = EventInjector.point(x: 0, y: 0.25, in: bounds)
        XCTAssertEqual(point.y, 450)
    }

    func testCoordonneesHorsBornesRamenees() {
        XCTAssertEqual(
            EventInjector.point(x: -1, y: 2, in: bounds),
            CGPoint(x: 5120, y: 1800)
        )
    }
}
