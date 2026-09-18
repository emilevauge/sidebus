import CoreGraphics
import XCTest

@testable import SidebusCore

final class CGVirtualDisplayProviderTests: XCTestCase {

    func testTaillePhysiqueDonneLaDensiteDemandee() {
        let configuration = CGVirtualDisplayProvider.Configuration(
            width: 2560,
            height: 1600,
            density: 320
        )
        // 2560 px à 320 dpi = 8 pouces = 203,2 mm.
        XCTAssertEqual(configuration.sizeInMillimeters.width, 203.2, accuracy: 0.1)
        XCTAssertEqual(configuration.sizeInMillimeters.height, 127.0, accuracy: 0.1)
    }

    func testModeHiDPISurDalleDense() {
        let dense = CGVirtualDisplayProvider.Configuration(width: 2560, height: 1600, density: 320)
        XCTAssertEqual(dense.pointSize.width, 1280)
        XCTAssertEqual(dense.pointSize.height, 800)

        // Dalle peu dense : pas de HiDPI, sinon l'interface serait énorme.
        let coarse = CGVirtualDisplayProvider.Configuration(width: 1920, height: 1200, density: 160)
        XCTAssertEqual(coarse.pointSize.width, 1920)
    }

    func testApiPriveePresente() {
        // Si ce test échoue sur une future version de macOS, c'est le signal que la
        // bascule sur ExistingDisplayProvider devient le chemin normal.
        XCTAssertTrue(
            CGVirtualDisplayProvider.isSupported,
            "les classes CGVirtualDisplay ont disparu de CoreGraphics"
        )
    }

    func testCreationEtRetraitDUnEcranReel() async throws {
        try XCTSkipUnless(
            CGVirtualDisplayProvider.isSupported,
            "API privée absente"
        )

        let before = try DisplayEnumerator.activeDisplayIDs()
        try XCTSkipIf(before.isEmpty, "aucun écran éveillé")

        let provider = CGVirtualDisplayProvider(
            configuration: .init(width: 2560, height: 1600, density: 320, name: "Sidebus test")
        )

        let id = try await provider.acquire()
        XCTAssertNotEqual(id, 0)

        // L'écran doit apparaître dans la liste des écrans actifs.
        try await Task.sleep(for: .milliseconds(500))
        let during = try DisplayEnumerator.activeDisplayIDs()
        XCTAssertTrue(during.contains(id), "l'écran virtuel n'est pas actif")
        XCTAssertEqual(during.count, before.count + 1)

        let bounds = CGDisplayBounds(id)
        XCTAssertEqual(bounds.width, 1280, "mode HiDPI attendu, donc 1280 points")

        await provider.release()
        try await Task.sleep(for: .milliseconds(500))
        let after = try DisplayEnumerator.activeDisplayIDs()
        XCTAssertFalse(after.contains(id), "l'écran virtuel n'a pas été retiré")
        XCTAssertEqual(after.count, before.count)
    }
}
