import CoreGraphics
import XCTest

@testable import SidebusCore

final class DisplayTests: XCTestCase {

    /// `CGGetActiveDisplayList` ne liste que les écrans éveillés : sur une machine dont
    /// l'écran dort, il n'y en a aucun. Les tests qui en ont besoin se sautent alors,
    /// plutôt que d'échouer pour une raison sans rapport avec le code.
    private func requireAwakeDisplay() throws -> CGDirectDisplayID {
        let ids = try DisplayEnumerator.activeDisplayIDs()
        try XCTSkipIf(ids.isEmpty, "aucun écran éveillé")
        return ids[0]
    }

    func testAuMoinsUnEcranActif() throws {
        let id = try requireAwakeDisplay()
        XCTAssertTrue(DisplayEnumerator.isActive(id))
    }

    func testEcranInexistantInactif() {
        XCTAssertFalse(DisplayEnumerator.isActive(CGDirectDisplayID.max))
    }

    @MainActor
    func testEnumerationComplete() throws {
        _ = try requireAwakeDisplay()
        let displays = try DisplayEnumerator.activeDisplays()
        XCTAssertEqual(displays.filter(\.isMain).count, 1)

        // Sert de diagnostic pour la validation de la phase 1 : l'écran de DeskPad
        // doit apparaître ici quand DeskPad tourne.
        for display in displays {
            print("écran \(display.id) : \(display.menuLabel)")
        }
    }

    func testProviderRendLIdentifiantVise() async throws {
        let id = try requireAwakeDisplay()
        let provider = ExistingDisplayProvider(targetID: id)
        let acquired = try await provider.acquire()
        XCTAssertEqual(acquired, id)
        await provider.release()
    }

    func testProviderRefuseUnEcranAbsent() async {
        let provider = ExistingDisplayProvider(targetID: .max)
        do {
            _ = try await provider.acquire()
            XCTFail("acquire() aurait dû échouer")
        } catch let error as DisplayError {
            guard case .displayUnavailable = error else {
                return XCTFail("erreur inattendue : \(error)")
            }
        } catch {
            XCTFail("erreur inattendue : \(error)")
        }
    }

    func testEchelleEtLibelle() {
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

    func testEcranPlusGrandQueLaTablette() {
        // DeskPad en 2880x1800 vers une dalle 2400x1080 : c'est la hauteur qui contraint.
        let size = CaptureSession.streamSize(
            display: CGSize(width: 2880, height: 1800),
            device: CGSize(width: 2400, height: 1080)
        )
        XCTAssertEqual(size, CGSize(width: 1728, height: 1080))
    }

    func testPasDAgrandissement() {
        // Une tablette plus grande que l'écran capturé ne fait pas monter la résolution.
        let size = CaptureSession.streamSize(
            display: CGSize(width: 1440, height: 900),
            device: CGSize(width: 2560, height: 1600)
        )
        XCTAssertEqual(size, CGSize(width: 1440, height: 900))
    }

    func testDimensionsPaires() {
        let size = CaptureSession.streamSize(
            display: CGSize(width: 1367, height: 769),
            device: CGSize(width: 1000, height: 1000)
        )
        XCTAssertEqual(size.width.truncatingRemainder(dividingBy: 2), 0)
        XCTAssertEqual(size.height.truncatingRemainder(dividingBy: 2), 0)
        XCTAssertLessThanOrEqual(size.width, 1000)
    }
}
