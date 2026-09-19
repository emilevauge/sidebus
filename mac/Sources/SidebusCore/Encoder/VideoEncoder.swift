import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

public struct VideoEncoderConfiguration: Sendable {
    public var width: Int
    public var height: Int
    public var fps: Int
    public var bitrate: Int
    public var maxKeyFrameInterval: Int
    /// Maximum interval between two keyframes, in seconds.
    ///
    /// An interval counted in frames protects nothing when the frame rate drops: 300
    /// frames at 7 fps is 43 seconds of corrupted picture after the smallest loss. A
    /// time bound holds at any frame rate.
    public var maxKeyFrameIntervalSeconds: Double
    /// HEVC costs 30 to 40 % less bitrate, which counts for a lot on Wi-Fi. Only chosen
    /// when the tablet announces it can decode it.
    public var codec: Codec

    public init(
        width: Int,
        height: Int,
        fps: Int = 60,
        bitrate: Int = 15_000_000,
        maxKeyFrameInterval: Int = 300,
        maxKeyFrameIntervalSeconds: Double = 2,
        codec: Codec = .h264
    ) {
        self.width = width
        self.height = height
        self.fps = fps
        self.bitrate = bitrate
        self.maxKeyFrameInterval = maxKeyFrameInterval
        self.maxKeyFrameIntervalSeconds = maxKeyFrameIntervalSeconds
        self.codec = codec
    }
}

public enum EncoderError: Error, CustomStringConvertible, Sendable {
    case sessionCreationFailed(OSStatus)
    case propertyFailed(String, OSStatus)
    case encodeFailed(OSStatus)
    case sessionClosed

    public var description: String {
        switch self {
        case let .sessionCreationFailed(status):
            return "cannot create the VideoToolbox session (OSStatus \(status))"
        case let .propertyFailed(key, status):
            return "property \(key) refused (OSStatus \(status))"
        case let .encodeFailed(status):
            return "encoding refused (OSStatus \(status))"
        case .sessionClosed:
            return "encoding session closed"
        }
    }
}

/// Hardware H.264 encoder, tuned for latency.
///
/// Takes `CVImageBuffer`s backed by an `IOSurface` and hands them straight to
/// VideoToolbox. Aucune copie de framebuffer.
public actor VideoEncoder {

    /// Stream of encoded frames, in presentation order.
    public nonisolated let frames: AsyncStream<EncodedFrame>

    private let sink: OutputSink
    private let configuration: VideoEncoderConfiguration
    private var session: VTCompressionSession?
    private var currentBitrate: Int
    private var keyframeRequested = false

    public init(configuration: VideoEncoderConfiguration) throws {
        self.configuration = configuration
        self.currentBitrate = configuration.bitrate

        let (stream, continuation) = AsyncStream<EncodedFrame>.makeStream(
            bufferingPolicy: .bufferingNewest(8)
        )
        frames = stream
        sink = OutputSink(continuation: continuation)

        // These two belong to the encoder specification, not to the session properties:
        // they are read when the encoder is chosen.
        let specification: [CFString: Any] = [
            kVTVideoEncoderSpecification_EnableLowLatencyRateControl: kCFBooleanTrue as Any,
            kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: kCFBooleanTrue as Any,
        ]

        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(configuration.width),
            height: Int32(configuration.height),
            codecType: configuration.codec == .hevc
                ? kCMVideoCodecType_HEVC
                : kCMVideoCodecType_H264,
            encoderSpecification: specification as CFDictionary,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &session
        )
        guard status == noErr, let session else {
            throw EncoderError.sessionCreationFailed(status)
        }
        self.session = session

        try Self.set(session, kVTCompressionPropertyKey_RealTime, true)
        // No B frames: they force reordering, so they force waiting.
        try Self.set(session, kVTCompressionPropertyKey_AllowFrameReordering, false)
        try Self.set(
            session,
            kVTCompressionPropertyKey_MaxKeyFrameInterval,
            configuration.maxKeyFrameInterval
        )
        try Self.set(
            session,
            kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration,
            configuration.maxKeyFrameIntervalSeconds
        )
        try Self.set(session, kVTCompressionPropertyKey_AverageBitRate, configuration.bitrate)
        try Self.set(session, kVTCompressionPropertyKey_ExpectedFrameRate, configuration.fps)

        VTCompressionSessionPrepareToEncodeFrames(session)
    }

    // The session is not invalidated here: `deinit` is not isolated and cannot touch the
    // actor's state. Call `finish()` before letting the encoder go. The session itself is
    // released along with the actor, CoreFoundation takes care of it.
    deinit {
        sink.finish()
    }

    /// Changes the target bitrate mid flight.
    public func setBitrate(_ bitrate: Int) {
        guard let session, bitrate != currentBitrate else { return }
        let status = VTSessionSetProperty(
            session,
            key: kVTCompressionPropertyKey_AverageBitRate,
            value: bitrate as CFNumber
        )
        if status == noErr { currentBitrate = bitrate }
    }

    public var bitrate: Int { currentBitrate }

    /// Asks for a keyframe on the next encoded frame. Used to answer KEYFRAME_REQ, when the
    /// decoder has lost the thread.
    public func requestKeyframe() {
        keyframeRequested = true
    }

    /// Encodes a frame. The result comes out later in `frames`.
    public func encode(_ frame: CapturedFrame) throws {
        guard let session else { throw EncoderError.sessionClosed }

        var properties: CFDictionary?
        if keyframeRequested {
            keyframeRequested = false
            properties = [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue] as CFDictionary
        }

        let sink = self.sink
        let status = VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: frame.imageBuffer,
            presentationTimeStamp: frame.presentationTime,
            duration: .invalid,
            frameProperties: properties,
            infoFlagsOut: nil
        ) { status, _, sampleBuffer in
            sink.handle(status: status, sampleBuffer: sampleBuffer)
        }

        guard status == noErr else { throw EncoderError.encodeFailed(status) }
    }

    /// Vide les frames en attente puis ferme la session.
    public func finish() async {
        guard let session else { return }
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        VTCompressionSessionInvalidate(session)
        self.session = nil
        sink.finish()
    }

    private static func set(
        _ session: VTCompressionSession,
        _ key: CFString,
        _ value: Bool
    ) throws {
        let status = VTSessionSetProperty(session, key: key, value: (value ? kCFBooleanTrue : kCFBooleanFalse))
        guard status == noErr else { throw EncoderError.propertyFailed(key as String, status) }
    }

    private static func set(
        _ session: VTCompressionSession,
        _ key: CFString,
        _ value: Double
    ) throws {
        let status = VTSessionSetProperty(session, key: key, value: value as CFNumber)
        guard status == noErr else { throw EncoderError.propertyFailed(key as String, status) }
    }

    private static func set(
        _ session: VTCompressionSession,
        _ key: CFString,
        _ value: Int
    ) throws {
        let status = VTSessionSetProperty(session, key: key, value: value as CFNumber)
        guard status == noErr else { throw EncoderError.propertyFailed(key as String, status) }
    }
}

/// Receives encoded frames on VideoToolbox's internal queue, converts them to
/// Annex B et les pousse dans le flux.
private final class OutputSink: @unchecked Sendable {
    private let lock = NSLock()
    private let continuation: AsyncStream<EncodedFrame>.Continuation
    private var lastFormatDescription: CMFormatDescription?

    init(continuation: AsyncStream<EncodedFrame>.Continuation) {
        self.continuation = continuation
    }

    func finish() {
        continuation.finish()
    }

    func handle(status: OSStatus, sampleBuffer: CMSampleBuffer?) {
        guard status == noErr,
            let sampleBuffer,
            sampleBuffer.isValid,
            CMSampleBufferDataIsReady(sampleBuffer),
            let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
            let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer)
        else { return }

        let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer,
            createIfNecessary: false
        ) as? [[CFString: Any]]
        let notSync = attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false
        let isKeyframe = !notSync

        let length = CMBlockBufferGetDataLength(blockBuffer)
        guard length > 0 else { return }

        var avcc = Data(count: length)
        let copyStatus = avcc.withUnsafeMutableBytes { buffer -> OSStatus in
            guard let base = buffer.baseAddress else { return kCMBlockBufferBadPointerParameterErr }
            return CMBlockBufferCopyDataBytes(
                blockBuffer,
                atOffset: 0,
                dataLength: length,
                destination: base
            )
        }
        guard copyStatus == kCMBlockBufferNoErr else { return }

        // Conversion in place: the bytes copied from the `CMBlockBuffer` become
        // directement de l'Annex B, sans seconde allocation.
        var data = avcc
        do {
            try AnnexB.convertInPlace(
                &data,
                nalLengthSize: AnnexB.nalLengthSize(of: formatDescription)
            )
        } catch {
            return
        }

        var parameterSets: Data?
        lock.lock()
        if lastFormatDescription == nil || !CMFormatDescriptionEqual(lastFormatDescription, otherFormatDescription: formatDescription) {
            lastFormatDescription = formatDescription
            parameterSets = AnnexB.parameterSets(from: formatDescription)
        }
        lock.unlock()

        continuation.yield(
            EncodedFrame(
                data: data,
                isKeyframe: isKeyframe,
                presentationTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer),
                parameterSets: parameterSets
            )
        )
    }
}
