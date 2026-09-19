import CoreMedia
import CoreMediaIO
import Foundation

/// The camera itself, as every application sees it.
///
/// One device, one stream, one format. More formats would mean negotiating a resolution
/// with each application, and the resolution here is whatever the phone is sending.
final class DeviceSource: NSObject, CMIOExtensionDeviceSource {

    private(set) var device: CMIOExtensionDevice!
    private var stream: StreamSource!

    init(localizedName: String) {
        super.init()
        device = CMIOExtensionDevice(
            localizedName: localizedName,
            deviceID: Extension.deviceUUID,
            legacyDeviceID: nil,
            source: self
        )

        var format: CMFormatDescription?
        CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: kCVPixelFormatType_32BGRA,
            width: Int32(StreamSource.width),
            height: Int32(StreamSource.height),
            extensions: nil,
            formatDescriptionOut: &format
        )
        guard let format else { return }

        stream = StreamSource(localizedName: "\(localizedName) video", format: format)
        do {
            try device.addStream(stream.stream)
        } catch {
            Extension.log.error("cannot add the stream: \(error.localizedDescription, privacy: .public)")
        }
    }

    var availableProperties: Set<CMIOExtensionProperty> {
        [.deviceTransportType, .deviceModel]
    }

    func deviceProperties(
        forProperties properties: Set<CMIOExtensionProperty>
    ) throws -> CMIOExtensionDeviceProperties {
        let result = CMIOExtensionDeviceProperties(dictionary: [:])
        if properties.contains(.deviceTransportType) {
            // 'virt': not plugged into anything. Applications read this to tell a built in
            // camera from one that can disappear. The constant lives in an IOAudio header
            // Swift does not import, hence the literal.
            result.transportType = 0x76697274
        }
        if properties.contains(.deviceModel) {
            result.model = "Sidebus Camera"
        }
        return result
    }

    func setDeviceProperties(_ deviceProperties: CMIOExtensionDeviceProperties) throws {}
}
