import XCTest

@testable import SidebusCore

final class DeviceDirectoryTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suite: String!

    override func setUp() {
        super.setUp()
        suite = "app.sidebus.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    private var directory: DeviceDirectory { DeviceDirectory(defaults: defaults) }

    func testAppareilInconnuAbsent() {
        XCTAssertNil(directory.device("inconnu"))
        XCTAssertFalse(directory.contains("inconnu"))
        XCTAssertTrue(directory.all().isEmpty)
    }

    func testEnregistrementPuisRelecture() {
        directory.record(deviceID: "A", name: "Xiaomi 15", transport: .usb)

        let device = directory.device("A")
        XCTAssertEqual(device?.name, "Xiaomi 15")
        XCTAssertEqual(device?.lastTransport, .usb)
        XCTAssertFalse(device?.resumesSharing ?? true)
    }

    /// Réenregistrer met à jour le nom sans effacer l'intention de partage : c'est ce qui
    /// fait qu'une tablette rebranchée reprend toute seule.
    func testReenregistrementConserveLaReprise() {
        directory.record(deviceID: "A", name: "Tab", transport: .wifi)
        directory.setResumesSharing(true, for: "A")

        directory.record(deviceID: "A", name: "Tab renommée", transport: .usb)

        let device = directory.device("A")
        XCTAssertEqual(device?.name, "Tab renommée")
        XCTAssertEqual(device?.lastTransport, .usb)
        XCTAssertTrue(device?.resumesSharing ?? false)
    }

    /// Un transport absent ne doit pas effacer le dernier connu : c'est lui qu'on affiche
    /// pour un appareil hors ligne.
    func testTransportNilNEcrasePas() {
        directory.record(deviceID: "A", name: "Tab", transport: .usb)
        directory.record(deviceID: "A", name: "Tab", transport: nil)

        XCTAssertEqual(directory.device("A")?.lastTransport, .usb)
    }

    func testListeDesReprises() {
        directory.record(deviceID: "A", name: "A", transport: .usb)
        directory.record(deviceID: "B", name: "B", transport: .wifi)
        directory.setResumesSharing(true, for: "B")

        XCTAssertEqual(directory.resuming(), ["B"])

        directory.setResumesSharing(false, for: "B")
        XCTAssertTrue(directory.resuming().isEmpty)
    }

    func testRepriseIgnoreUnAppareilAbsent() {
        directory.setResumesSharing(true, for: "fantôme")
        XCTAssertTrue(directory.resuming().isEmpty)
    }

    func testSuppression() {
        directory.record(deviceID: "A", name: "A", transport: .usb)
        directory.record(deviceID: "B", name: "B", transport: .usb)

        directory.remove("A")
        XCTAssertNil(directory.device("A"))
        XCTAssertNotNil(directory.device("B"))

        directory.removeAll()
        XCTAssertTrue(directory.all().isEmpty)
    }

    /// Le plus récemment vu arrive en tête : c'est l'ordre de la fenêtre de réglages.
    func testTriParDerniereVue() throws {
        directory.record(deviceID: "vieux", name: "vieux", transport: .usb)
        var entry = try XCTUnwrap(directory.device("vieux"))
        entry.lastSeen = Date(timeIntervalSinceNow: -3600)
        // Réécriture directe : `record` remet toujours l'horodatage à maintenant.
        let encoded = try JSONEncoder().encode(["vieux": entry])
        defaults.set(encoded, forKey: DeviceDirectory.storageKey)

        directory.record(deviceID: "récent", name: "récent", transport: .wifi)

        XCTAssertEqual(directory.all().map(\.deviceID), ["récent", "vieux"])
    }
}
