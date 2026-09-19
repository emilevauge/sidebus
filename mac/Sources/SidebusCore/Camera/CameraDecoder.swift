import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox
import os

/// Decodes the camera stream coming back from the tablet.
///
/// The mirror image of `VideoEncoder`: same Annex B on the wire, same hardware path, the
/// other way round. VideoToolbox wants AVCC, so the start codes are rewritten into length
/// prefixes in place, exactly as `AnnexB.convertInPlace` does for the outgoing direction.
public actor CameraDecoder {

    public enum DecodeError: Error, CustomStringConvertible, Sendable {
        case noFormatDescription(OSStatus)
        case sessionFailed(OSStatus)
        case decodeFailed(OSStatus)

        public var description: String {
            switch self {
            case let .noFormatDescription(status):
                return "cannot build the format description (OSStatus \(status))"
            case let .sessionFailed(status):
                return "cannot create the decompression session (OSStatus \(status))"
            case let .decodeFailed(status):
                return "decoding refused (OSStatus \(status))"
            }
        }
    }

    /// Decoded frames, in the order VideoToolbox produces them. `CapturedFrame` carries the
    /// same `@unchecked Sendable` reasoning as on the capture side: the buffer crosses the
    /// pipeline read only.
    public nonisolated let frames: AsyncStream<CapturedFrame>

    private let continuation: AsyncStream<CapturedFrame>.Continuation
    private var session: VTDecompressionSession?
    private var formatDescription: CMFormatDescription?
    private let log = Logger(subsystem: "app.sidebus", category: "camera")

    public init() {
        let (stream, continuation) = AsyncStream<CapturedFrame>.makeStream(
            bufferingPolicy: .bufferingNewest(2)
        )
        frames = stream
        self.continuation = continuation
    }

    /// Feeds the parameter sets from CAMERA_CONFIG and arms the session.
    public func configure(width: Int, height: Int, codec: Codec, parameterSets: Data) throws {
        let sets = AnnexB.split(parameterSets)
        guard !sets.isEmpty else { throw DecodeError.noFormatDescription(-1) }

        var description: CMFormatDescription?
        let status: OSStatus = sets.withUnsafePointers { pointers, sizes in
            if codec == .hevc {
                return CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: pointers.count,
                    parameterSetPointers: pointers.baseAddress!,
                    parameterSetSizes: sizes.baseAddress!,
                    nalUnitHeaderLength: 4,
                    extensions: nil,
                    formatDescriptionOut: &description
                )
            }
            return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                allocator: kCFAllocatorDefault,
                parameterSetCount: pointers.count,
                parameterSetPointers: pointers.baseAddress!,
                parameterSetSizes: sizes.baseAddress!,
                nalUnitHeaderLength: 4,
                formatDescriptionOut: &description
            )
        }
        guard status == noErr, let description else {
            throw DecodeError.noFormatDescription(status)
        }

        finishSession()
        formatDescription = description

        // Ask for an IOSurface backed buffer: the preview draws it without a copy.
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]

        var callback = VTDecompressionOutputCallbackRecord(
            decompressionOutputCallback: { context, _, status, _, imageBuffer, time, _ in
                guard status == noErr, let imageBuffer, let context else { return }
                let sink = Unmanaged<Sink>.fromOpaque(context).takeUnretainedValue()
                sink.yield(CapturedFrame(imageBuffer: imageBuffer, presentationTime: time))
            },
            decompressionOutputRefCon: Unmanaged.passUnretained(sink).toOpaque()
        )

        var created: VTDecompressionSession?
        let sessionStatus = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: description,
            decoderSpecification: nil,
            imageBufferAttributes: attributes as CFDictionary,
            outputCallback: &callback,
            decompressionSessionOut: &created
        )
        guard sessionStatus == noErr, let created else {
            throw DecodeError.sessionFailed(sessionStatus)
        }
        session = created
        log.info("camera decoder ready, \(width)×\(height)")
    }

    /// Feeds one CAMERA_FRAME. Returns without complaining before the session exists: the
    /// frames that precede CAMERA_CONFIG cannot be decoded and are not worth an error.
    public func decode(_ data: Data, timestamp: UInt64) throws {
        guard let session, let formatDescription else { return }

        var avcc = data
        AnnexB.convertToLengthPrefixed(&avcc)

        var blockBuffer: CMBlockBuffer?
        let bytes = UnsafeMutableRawPointer.allocate(
            byteCount: avcc.count,
            alignment: MemoryLayout<UInt8>.alignment
        )
        avcc.copyBytes(to: bytes.assumingMemoryBound(to: UInt8.self), count: avcc.count)

        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: bytes,
            blockLength: avcc.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: avcc.count,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr, let blockBuffer else {
            bytes.deallocate()
            throw DecodeError.decodeFailed(status)
        }

        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMTime(value: CMTimeValue(timestamp), timescale: 1_000_000),
            decodeTimeStamp: .invalid
        )
        var sampleSize = avcc.count
        var sampleBuffer: CMSampleBuffer?
        status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )
        guard status == noErr, let sampleBuffer else { throw DecodeError.decodeFailed(status) }

        status = VTDecompressionSessionDecodeFrame(
            session,
            sampleBuffer: sampleBuffer,
            flags: [._EnableAsynchronousDecompression, ._EnableTemporalProcessing],
            frameRefcon: nil,
            infoFlagsOut: nil
        )
        guard status == noErr else { throw DecodeError.decodeFailed(status) }
    }

    public func stop() {
        finishSession()
        continuation.finish()
    }

    private func finishSession() {
        if let session {
            VTDecompressionSessionInvalidate(session)
        }
        session = nil
        formatDescription = nil
    }

    /// Bridges the C callback back into the `AsyncStream`. A class, because the callback
    /// only carries an opaque pointer.
    private final class Sink: @unchecked Sendable {
        var continuation: AsyncStream<CapturedFrame>.Continuation?
        func yield(_ frame: CapturedFrame) { continuation?.yield(frame) }
    }

    private lazy var sink: Sink = {
        let sink = Sink()
        sink.continuation = continuation
        return sink
    }()
}

private extension Array where Element == Data {
    /// Hands the parameter sets to CoreMedia as the pair of C arrays it expects.
    func withUnsafePointers<T>(
        _ body: (UnsafeBufferPointer<UnsafePointer<UInt8>>, UnsafeBufferPointer<Int>) -> T
    ) -> T {
        var pointers: [UnsafePointer<UInt8>] = []
        var sizes: [Int] = []
        var keepAlive: [UnsafeMutableBufferPointer<UInt8>] = []

        for set in self {
            let buffer = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: set.count)
            _ = buffer.initialize(from: set)
            keepAlive.append(buffer)
            pointers.append(UnsafePointer(buffer.baseAddress!))
            sizes.append(set.count)
        }
        defer { keepAlive.forEach { $0.deallocate() } }

        return pointers.withUnsafeBufferPointer { pointerBuffer in
            sizes.withUnsafeBufferPointer { sizeBuffer in
                body(pointerBuffer, sizeBuffer)
            }
        }
    }
}
