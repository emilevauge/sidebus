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

    func testTabletSeenOnBothTransportsAppearsOnce() {
        let registry = PeerRegistry(
            usbPeers: [usb("R5CT80ABCDE")],
            wifiPeers: [wifi("Galaxy Tab S9", deviceID: deviceID)],
            serialToDevice: ["R5CT80ABCDE": deviceID]
        )

        let resolved = registry.resolved()
        XCTAssertEqual(resolved.count, 1)
        XCTAssertEqual(resolved.first?.kind, .usb)
    }

    func testWithNoKnownMappingBothRemain() {
        // A tablet never connected over USB: no way to know it is the same one.
        let registry = PeerRegistry(
            usbPeers: [usb("R5CT80ABCDE")],
            wifiPeers: [wifi("Galaxy Tab S9", deviceID: deviceID)]
        )
        XCTAssertEqual(registry.resolved().count, 2)
    }

    func testADifferentWifiTabletIsKept() {
        let autre = UUID()
        let registry = PeerRegistry(
            usbPeers: [usb("R5CT80ABCDE")],
            wifiPeers: [wifi("Tablette du salon", deviceID: autre)],
            serialToDevice: ["R5CT80ABCDE": deviceID]
        )
        XCTAssertEqual(registry.resolved().count, 2)
        XCTAssertEqual(registry.preferred()?.kind, .usb)
    }

    func testUsbWinsEvenWhenDiscoveredLater() {
        let registry = PeerRegistry(
            usbPeers: [usb("R5CT80ABCDE")],
            wifiPeers: [wifi("Galaxy Tab S9", deviceID: deviceID)]
        )
        XCTAssertEqual(registry.preferred()?.kind, .usb)
    }

    func testSwitchesOnlyFromWifiToUsb() {
        let registry = PeerRegistry()
        let wifiPeer = wifi("Galaxy Tab S9", deviceID: deviceID)
        let usbPeer = usb("R5CT80ABCDE")

        XCTAssertTrue(registry.shouldSwitch(from: nil, to: usbPeer))
        XCTAssertTrue(registry.shouldSwitch(from: wifiPeer, to: usbPeer))
        XCTAssertFalse(registry.shouldSwitch(from: usbPeer, to: wifiPeer))
        XCTAssertFalse(registry.shouldSwitch(from: usbPeer, to: usbPeer))
        XCTAssertFalse(registry.shouldSwitch(from: wifiPeer, to: nil))
    }

    func testNoTablet() {
        XCTAssertTrue(PeerRegistry().resolved().isEmpty)
        XCTAssertNil(PeerRegistry().preferred())
    }
}

/// Stopping the share must stick: without that, discovery picks the tablet up at once.
final class SharingStateTests: XCTestCase {

    private let key = "sharingEnabled.test"

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: key)
        super.tearDown()
    }

    func testDefaultStateIsActive() {
        UserDefaults.standard.removeObject(forKey: key)
        let stored = UserDefaults.standard.object(forKey: key) as? Bool ?? true
        XCTAssertTrue(stored)
    }

    func testStatePersists() {
        UserDefaults.standard.set(false, forKey: key)
        XCTAssertEqual(UserDefaults.standard.object(forKey: key) as? Bool, false)
    }
}
