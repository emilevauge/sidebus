import Foundation
import XCTest

@testable import SidebusCore

final class PeerRegistryTests: XCTestCase {

    private let deviceID = UUID(uuidString: "7C9E6679-7425-40DE-944B-E07FC1F90AE7")!

    private func usb(_ serial: String) -> Peer {
        Peer(id: serial, name: serial, kind: .usb, host: "127.0.0.1", port: 27183)
    }

    private func wifi(_ name: String, deviceID: UUID?) -> Peer {
        Peer(id: name, name: name, kind: .wifi, host: "192.168.1.20", port: 27183, deviceID: deviceID)
    }

    func testTabletteVueSurLesDeuxTransportsNApparaitQuUneFois() {
        let registry = PeerRegistry(
            usbPeers: [usb("R5CT80ABCDE")],
            wifiPeers: [wifi("Galaxy Tab S9", deviceID: deviceID)],
            serialToDevice: ["R5CT80ABCDE": deviceID]
        )

        let resolved = registry.resolved()
        XCTAssertEqual(resolved.count, 1)
        XCTAssertEqual(resolved.first?.kind, .usb)
    }

    func testSansCorrespondanceConnueLesDeuxRestent() {
        // Tablette jamais connectée en USB : impossible de savoir que c'est la même.
        let registry = PeerRegistry(
            usbPeers: [usb("R5CT80ABCDE")],
            wifiPeers: [wifi("Galaxy Tab S9", deviceID: deviceID)]
        )
        XCTAssertEqual(registry.resolved().count, 2)
    }

    func testTabletteWifiDifferenteEstConservee() {
        let autre = UUID()
        let registry = PeerRegistry(
            usbPeers: [usb("R5CT80ABCDE")],
            wifiPeers: [wifi("Tablette du salon", deviceID: autre)],
            serialToDevice: ["R5CT80ABCDE": deviceID]
        )
        XCTAssertEqual(registry.resolved().count, 2)
        XCTAssertEqual(registry.preferred()?.kind, .usb)
    }

    func testLUsbEstPrefereMemeDecouvertApres() {
        let registry = PeerRegistry(
            usbPeers: [usb("R5CT80ABCDE")],
            wifiPeers: [wifi("Galaxy Tab S9", deviceID: deviceID)]
        )
        XCTAssertEqual(registry.preferred()?.kind, .usb)
    }

    func testBasculeSeulementDuWifiVersLUsb() {
        let registry = PeerRegistry()
        let wifiPeer = wifi("Galaxy Tab S9", deviceID: deviceID)
        let usbPeer = usb("R5CT80ABCDE")

        XCTAssertTrue(registry.shouldSwitch(from: nil, to: usbPeer))
        XCTAssertTrue(registry.shouldSwitch(from: wifiPeer, to: usbPeer))
        XCTAssertFalse(registry.shouldSwitch(from: usbPeer, to: wifiPeer))
        XCTAssertFalse(registry.shouldSwitch(from: usbPeer, to: usbPeer))
        XCTAssertFalse(registry.shouldSwitch(from: wifiPeer, to: nil))
    }

    func testAucuneTablette() {
        XCTAssertTrue(PeerRegistry().resolved().isEmpty)
        XCTAssertNil(PeerRegistry().preferred())
    }
}

/// L'arrêt du partage doit tenir : sans ça, la découverte reprend la tablette aussitôt.
final class SharingStateTests: XCTestCase {

    private let key = "sharingEnabled.test"

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: key)
        super.tearDown()
    }

    func testEtatParDefautEstActif() {
        UserDefaults.standard.removeObject(forKey: key)
        let stored = UserDefaults.standard.object(forKey: key) as? Bool ?? true
        XCTAssertTrue(stored)
    }

    func testEtatPersiste() {
        UserDefaults.standard.set(false, forKey: key)
        XCTAssertEqual(UserDefaults.standard.object(forKey: key) as? Bool, false)
    }
}
