import Foundation
import XCTest

@testable import SidebusCore

final class PairingCodeTests: XCTestCase {

    func testCodeDeriveDesQuatrePremiersOctets() {
        // 0x00 0x0F 0x42 0x40 = 1 000 000 -> 000000 après le modulo.
        XCTAssertEqual(PairingCode.code(for: Data([0x00, 0x0F, 0x42, 0x40, 0xFF])), "000000")
        // 0x00 0x00 0x30 0x39 = 12 345.
        XCTAssertEqual(PairingCode.code(for: Data([0x00, 0x00, 0x30, 0x39])), "012345")
    }

    func testCodeToujoursSurSixChiffres() {
        for byte in UInt8(0)...UInt8(32) {
            let code = PairingCode.code(for: Data([byte, byte, byte, byte]))
            XCTAssertEqual(code.count, 6)
            XCTAssertTrue(code.allSatisfy(\.isNumber))
        }
    }

    func testEmpreinteEstUnSha256() {
        let fingerprint = PairingCode.fingerprint(ofDER: Data("certificat".utf8))
        XCTAssertEqual(fingerprint.count, 32)
        // Stable d'un appel à l'autre, sinon rien ne pourrait être épinglé.
        XCTAssertEqual(fingerprint, PairingCode.fingerprint(ofDER: Data("certificat".utf8)))
    }

    /// Le code doit être le même des deux côtés : ce vecteur est recalculé à l'identique
    /// par le test Kotlin `pairingCodeIdentiqueAuMac`.
    func testVecteurPartageAvecAndroid() {
        let fingerprint = Data((0..<32).map { UInt8($0) })
        XCTAssertEqual(PairingCode.code(for: fingerprint), "066051")
    }
}

final class PairingStoreTests: XCTestCase {
    private let deviceID = "test-" + UUID().uuidString
    /// Service dédié : énumérer celui de l'application déclencherait une demande
    /// d'autorisation du trousseau, qui bloque le test.
    private let store = PairingStore(service: "app.sidebus.pairing.tests")

    override func tearDown() {
        store.remove(deviceID: deviceID)
        super.tearDown()
    }

    func testIndexInverseTrouveLAppareil() throws {
        let fingerprint = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        try store.save(fingerprint, forDeviceID: deviceID)
        XCTAssertEqual(store.deviceID(for: fingerprint), deviceID)
        XCTAssertNil(store.deviceID(for: Data(repeating: 0xAB, count: 32)))
    }

    func testEnregistreRelitEtSupprime() throws {
        let fingerprint = Data((0..<32).map { _ in UInt8.random(in: 0...255) })

        XCTAssertNil(store.fingerprint(forDeviceID: deviceID))

        try store.save(fingerprint, forDeviceID: deviceID)
        XCTAssertEqual(store.fingerprint(forDeviceID: deviceID), fingerprint)
        XCTAssertTrue(store.isKnown(fingerprint))
        XCTAssertEqual(store.deviceID(for: fingerprint), deviceID)

        // Réenregistrer met à jour au lieu d'échouer sur un doublon.
        let rotated = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        try store.save(rotated, forDeviceID: deviceID)
        XCTAssertEqual(store.fingerprint(forDeviceID: deviceID), rotated)

        store.remove(deviceID: deviceID)
        XCTAssertNil(store.fingerprint(forDeviceID: deviceID))
    }
}
