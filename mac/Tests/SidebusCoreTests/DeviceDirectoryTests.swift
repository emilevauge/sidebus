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

    func testUnknownDeviceIsAbsent() {
        XCTAssertNil(directory.device("inconnu"))
        XCTAssertFalse(directory.contains("inconnu"))
        XCTAssertTrue(directory.all().isEmpty)
    }

    func testRecordThenReadBack() {
        directory.record(deviceID: "A", name: "Xiaomi 15", transport: .usb)

        let device = directory.device("A")
        XCTAssertEqual(device?.name, "Xiaomi 15")
        XCTAssertEqual(device?.lastTransport, .usb)
        XCTAssertFalse(device?.resumesSharing ?? true)
    }

    /// Recording again updates the name without erasing the sharing intent: that is what
    /// makes a replugged tablet resume on its own.
    func testRerecordingKeepsTheResumeIntent() {
        directory.record(deviceID: "A", name: "Tab", transport: .wifi)
        directory.setResumesSharing(true, for: "A")

        directory.record(deviceID: "A", name: "Renamed tab", transport: .usb)

        let device = directory.device("A")
        XCTAssertEqual(device?.name, "Renamed tab")
        XCTAssertEqual(device?.lastTransport, .usb)
        XCTAssertTrue(device?.resumesSharing ?? false)
    }

    /// A missing transport must not erase the last known one: that is what an offline device
    /// displays.
    func testNilTransportDoesNotOverwrite() {
        directory.record(deviceID: "A", name: "Tab", transport: .usb)
        directory.record(deviceID: "A", name: "Tab", transport: nil)

        XCTAssertEqual(directory.device("A")?.lastTransport, .usb)
    }

    func testResumeList() {
        directory.record(deviceID: "A", name: "A", transport: .usb)
        directory.record(deviceID: "B", name: "B", transport: .wifi)
        directory.setResumesSharing(true, for: "B")

        XCTAssertEqual(directory.resuming(), ["B"])

        directory.setResumesSharing(false, for: "B")
        XCTAssertTrue(directory.resuming().isEmpty)
    }

    func testResumeIgnoresAMissingDevice() {
        directory.setResumesSharing(true, for: "ghost")
        XCTAssertTrue(directory.resuming().isEmpty)
    }

    func testRemoval() {
        directory.record(deviceID: "A", name: "A", transport: .usb)
        directory.record(deviceID: "B", name: "B", transport: .usb)

        directory.remove("A")
        XCTAssertNil(directory.device("A"))
        XCTAssertNotNil(directory.device("B"))

        directory.removeAll()
        XCTAssertTrue(directory.all().isEmpty)
    }

    /// Most recently seen comes first: that is the order of the settings window.
    func testSortedByLastSeen() throws {
        directory.record(deviceID: "old", name: "old", transport: .usb)
        var entry = try XCTUnwrap(directory.device("old"))
        entry.lastSeen = Date(timeIntervalSinceNow: -3600)
        // Direct rewrite: `record` always resets the timestamp to now.
        let encoded = try JSONEncoder().encode(["old": entry])
        defaults.set(encoded, forKey: DeviceDirectory.storageKey)

        directory.record(deviceID: "recent", name: "recent", transport: .wifi)

        XCTAssertEqual(directory.all().map(\.deviceID), ["recent", "old"])
    }
}
