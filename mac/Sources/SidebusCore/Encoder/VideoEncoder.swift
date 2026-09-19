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
    /// Intervalle maximal entre deux keyframes, en secondes.
    ///
    /// Un intervalle exprimé en nombre de frames ne protège de rien quand la cadence
    /// tombe : 300 frames à 7 fps font 43 secondes d'image corrompue après la moindre
    /// perte. Une borne temporelle tient quelle que soit la cadence.
    public var maxKeyFrameIntervalSeconds: Double
    /// HEVC coûte 30 à 40 % de débit en moins, ce qui compte beaucoup en Wi-Fi. Retenu
    /// seulement si la tablette annonce savoir le décoder.
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
            return "création de la session VideoToolbox impossible (OSStatus \(status))"
        case let .propertyFailed(key, status):
            return "propriété \(key) refusée (OSStatus \(status))"
        case let .encodeFailed(status):
            return "encodage refusé (OSStatus \(status))"
        case .sessionClosed:
            return "session d'encodage fermée"
        }
    }
}

/// Encodeur H.264 matériel, réglé pour la latence.
///
/// Reçoit des `CVImageBuffer` adossés à un `IOSurface` et les passe directement à
/// VideoToolbox. Aucune copie de framebuffer.
public actor VideoEncoder {

    /// Flux des frames encodées, dans l'ordre de présentation.
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

        // Ces deux réglages appartiennent à la spécification de l'encodeur, pas aux
        // propriétés de session : ils sont lus au moment de choisir l'encodeur.
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
        // Pas de B frames : elles imposent de réordonner, donc d'attendre.
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

    // Pas d'invalidation de la session ici : `deinit` n'est pas isolé et ne peut pas
    // toucher à l'état de l'acteur. Appeler `finish()` avant de lâcher l'encodeur.
    // La session elle même est libérée avec l'acteur, CoreFoundation s'en charge.
    deinit {
        sink.finish()
    }

    /// Change le débit visé en cours de route.
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

    /// Demande une keyframe sur la prochaine frame encodée. Sert à répondre à
    /// KEYFRAME_REQ, quand le décodeur a perdu le fil.
    public func requestKeyframe() {
        keyframeRequested = true
    }

    /// Encode une frame. Le résultat sort plus tard dans `frames`.
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

/// Reçoit les frames encodées sur la file interne de VideoToolbox, les convertit en
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

        guard let data = try? AnnexB.fromLengthPrefixed(
            avcc,
            nalLengthSize: AnnexB.nalLengthSize(of: formatDescription)
        ) else { return }

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
