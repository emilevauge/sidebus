import CoreMediaIO
import Foundation
import os

/// Publishes one camera to the whole system.
///
/// A Core Media I/O extension is what makes a device appear in Zoom, Meet, QuickTime and
/// anything else that opens a camera. It runs outside the app, sandboxed, started by the
/// system when something wants the camera and stopped when nothing does.
final class ProviderSource: NSObject, CMIOExtensionProviderSource {

    private(set) var provider: CMIOExtensionProvider!
    private var device: DeviceSource!

    init(clientQueue: DispatchQueue?) {
        super.init()
        provider = CMIOExtensionProvider(source: self, clientQueue: clientQueue)
        device = DeviceSource(localizedName: "Sidebus")
        do {
            try provider.addDevice(device.device)
        } catch {
            Extension.log.error("cannot publish the device: \(error.localizedDescription, privacy: .public)")
        }
    }

    // A client here is an application that opened the camera. Nothing to set up per client:
    // every one of them gets the same stream.
    func connect(to client: CMIOExtensionClient) throws {}

    func disconnect(from client: CMIOExtensionClient) {}

    var availableProperties: Set<CMIOExtensionProperty> {
        [.providerManufacturer]
    }

    func providerProperties(
        forProperties properties: Set<CMIOExtensionProperty>
    ) throws -> CMIOExtensionProviderProperties {
        let result = CMIOExtensionProviderProperties(dictionary: [:])
        if properties.contains(.providerManufacturer) {
            result.manufacturer = "Sidebus"
        }
        return result
    }

    func setProviderProperties(_ providerProperties: CMIOExtensionProviderProperties) throws {}
}

enum Extension {
    static let log = Logger(subsystem: "app.sidebus.camera", category: "extension")

    /// Identifiers the system keys the device on. Stable across launches, otherwise every
    /// application that remembered the camera would lose it on the next install.
    static let deviceUUID = UUID(uuidString: "6F1C5A7E-1D2B-4E3F-8A90-5C7B2E4D6A11")!
    static let streamUUID = UUID(uuidString: "6F1C5A7E-1D2B-4E3F-8A90-5C7B2E4D6A12")!
}
