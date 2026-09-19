import CoreGraphics
import CoreMedia
import CoreMediaIO
import Foundation

/// The frames the camera hands out.
///
/// For now a placeholder picture, drawn here. It exists to answer one question before any
/// of the plumbing is built: does a self signed extension carrying a restricted entitlement
/// install and publish a camera at all. Real frames arrive from the phone in a second step.
final class StreamSource: NSObject, CMIOExtensionStreamSource {

    static let width = 1280
    static let height = 720
    static let frameRate = 30

    private(set) var stream: CMIOExtensionStream!
    private let format: CMFormatDescription

    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "app.sidebus.camera.frames", qos: .userInitiated)
    private var pool: CVPixelBufferPool?
    private var frameNumber: UInt64 = 0

    /// Number of applications currently reading. The timer only runs while at least one is.
    private var readers = 0

    init(localizedName: String, format: CMFormatDescription) {
        self.format = format
        super.init()
        stream = CMIOExtensionStream(
            localizedName: localizedName,
            streamID: Extension.streamUUID,
            direction: .source,
            clockType: .hostTime,
            source: self
        )
        pool = Self.makePool()
    }

    var formats: [CMIOExtensionStreamFormat] {
        [
            CMIOExtensionStreamFormat(
                formatDescription: format,
                maxFrameDuration: CMTime(value: 1, timescale: CMTimeScale(Self.frameRate)),
                minFrameDuration: CMTime(value: 1, timescale: CMTimeScale(Self.frameRate)),
                validFrameDurations: nil
            )
        ]
    }

    var availableProperties: Set<CMIOExtensionProperty> {
        [.streamActiveFormatIndex, .streamFrameDuration]
    }

    func streamProperties(
        forProperties properties: Set<CMIOExtensionProperty>
    ) throws -> CMIOExtensionStreamProperties {
        let result = CMIOExtensionStreamProperties(dictionary: [:])
        if properties.contains(.streamActiveFormatIndex) {
            result.activeFormatIndex = 0
        }
        if properties.contains(.streamFrameDuration) {
            result.frameDuration = CMTime(value: 1, timescale: CMTimeScale(Self.frameRate))
        }
        return result
    }

    func setStreamProperties(_ streamProperties: CMIOExtensionStreamProperties) throws {}

    /// Every application is allowed to open the camera. Restricting it here would only make
    /// the device look broken in the applications that were turned away.
    func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool { true }

    func startStream() throws {
        readers += 1
        guard readers == 1 else { return }

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(
            deadline: .now(),
            repeating: 1.0 / Double(Self.frameRate),
            leeway: .milliseconds(2)
        )
        timer.setEventHandler { [weak self] in self?.sendFrame() }
        self.timer = timer
        timer.resume()
        Extension.log.info("stream started")
    }

    func stopStream() throws {
        readers = max(0, readers - 1)
        guard readers == 0 else { return }
        timer?.cancel()
        timer = nil
        Extension.log.info("stream stopped")
    }

    // MARK: - Frames

    private static func makePool() -> CVPixelBufferPool? {
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            // The consumer is another process, so the buffer has to be shareable.
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        var pool: CVPixelBufferPool?
        CVPixelBufferPoolCreate(
            kCFAllocatorDefault,
            nil,
            attributes as CFDictionary,
            &pool
        )
        return pool
    }

    private func sendFrame() {
        guard let pool else { return }

        var buffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer) == kCVReturnSuccess,
            let buffer
        else { return }

        draw(into: buffer)
        frameNumber += 1

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(Self.frameRate)),
            presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
            decodeTimeStamp: .invalid
        )

        var description: CMFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: buffer,
            formatDescriptionOut: &description
        ) == noErr, let description else { return }

        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: buffer,
            formatDescription: description,
            sampleTiming: &timing,
            sampleBufferOut: &sample
        ) == noErr, let sample else { return }

        stream.send(
            sample,
            discontinuity: [],
            hostTimeInNanoseconds: UInt64(
                timing.presentationTimeStamp.seconds * Double(NSEC_PER_SEC)
            )
        )
    }

    /// A dark background with a bar sweeping across it, so a still picture cannot be
    /// mistaken for a live one.
    private func draw(into buffer: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        guard let base = CVPixelBufferGetBaseAddress(buffer),
            let space = CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(
                data: base,
                width: CVPixelBufferGetWidth(buffer),
                height: CVPixelBufferGetHeight(buffer),
                bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                    | CGBitmapInfo.byteOrder32Little.rawValue
            )
        else { return }

        let size = CGSize(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer))
        context.setFillColor(red: 0.07, green: 0.1, blue: 0.2, alpha: 1)
        context.fill(CGRect(origin: .zero, size: size))

        let period = Double(Self.frameRate * 2)
        let progress = Double(frameNumber % UInt64(period)) / period
        context.setFillColor(red: 1, green: 0.78, blue: 0.24, alpha: 1)
        context.fill(
            CGRect(x: progress * size.width, y: 0, width: size.width / 12, height: size.height)
        )
    }
}
