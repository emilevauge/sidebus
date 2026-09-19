import CoreMedia
import Foundation

/// Conversion from VideoToolbox's output format to Annex B.
///
/// VideoToolbox emits NAL units prefixed with their length (AVCC format). The Sidebus wire
/// and `MediaCodec` expect Annex B, that is NAL units separated by the `00 00 00 01` start
/// code. See `protocol/PROTOCOL.md`, messages VIDEO_CONFIG and VIDEO_FRAME.
public enum AnnexB {
    public static let startCode = Data([0x00, 0x00, 0x00, 0x01])

    public enum Error: Swift.Error, CustomStringConvertible, Sendable {
        case invalidLengthSize(Int)
        case truncated(offset: Int)

        public var description: String {
            switch self {
            case let .invalidLengthSize(size):
                return "invalid NAL length prefix size: \(size)"
            case let .truncated(offset):
                return "truncated AVCC stream at offset \(offset)"
            }
        }
    }

    /// Convertit un buffer AVCC en Annex B.
    ///
    /// - Parameter nalLengthSize: size of the length prefix, 1 to 4 bytes, announced by
    ///   the format description. In practice it is 4.
    public static func fromLengthPrefixed(_ avcc: Data, nalLengthSize: Int) throws -> Data {
        guard (1...4).contains(nalLengthSize) else {
            throw Error.invalidLengthSize(nalLengthSize)
        }

        var output = Data()
        output.reserveCapacity(avcc.count + 8)

        var offset = avcc.startIndex
        while offset < avcc.endIndex {
            guard avcc.index(offset, offsetBy: nalLengthSize, limitedBy: avcc.endIndex) != nil else {
                throw Error.truncated(offset: avcc.distance(from: avcc.startIndex, to: offset))
            }

            // The length prefix is big endian, unlike the rest of the protocol.
            var length = 0
            for index in 0..<nalLengthSize {
                length = (length << 8) | Int(avcc[avcc.index(offset, offsetBy: index)])
            }
            offset = avcc.index(offset, offsetBy: nalLengthSize)

            guard let end = avcc.index(offset, offsetBy: length, limitedBy: avcc.endIndex) else {
                throw Error.truncated(offset: avcc.distance(from: avcc.startIndex, to: offset))
            }

            output.append(startCode)
            output.append(avcc[offset..<end])
            offset = end
        }

        return output
    }

    /// Convertit un buffer AVCC en Annex B **sur place**, sans allouer.
    ///
    /// The length prefix is four bytes and so is the start code, so rewriting those four
    /// length bytes as `00 00 00 01` is enough. That removes a full copy of every encoded
    /// frame.
    ///
    /// Prefix sizes other than four, never seen out of VideoToolbox,
    /// retombent sur la conversion avec allocation.
    public static func convertInPlace(_ data: inout Data, nalLengthSize: Int) throws {
        guard nalLengthSize == 4 else {
            data = try fromLengthPrefixed(data, nalLengthSize: nalLengthSize)
            return
        }

        try data.withUnsafeMutableBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            let count = raw.count
            var offset = 0

            while offset < count {
                guard offset + 4 <= count else {
                    throw Error.truncated(offset: offset)
                }
                let length = (Int(base[offset]) << 24)
                    | (Int(base[offset + 1]) << 16)
                    | (Int(base[offset + 2]) << 8)
                    | Int(base[offset + 3])
                guard length >= 0, offset + 4 + length <= count else {
                    throw Error.truncated(offset: offset + 4)
                }

                base[offset] = 0
                base[offset + 1] = 0
                base[offset + 2] = 0
                base[offset + 3] = 1
                offset += 4 + length
            }
        }
    }

    /// Parameter sets of a format description, concatenated in Annex B: SPS and PPS for
    /// H.264, VPS, SPS and PPS for HEVC.
    public static func parameterSets(from formatDescription: CMFormatDescription) -> Data? {
        let isHEVC = formatDescription.mediaSubType == .hevc
        guard isHEVC || formatDescription.mediaSubType == .h264 else { return nil }

        var count = 0
        let countStatus = isHEVC
            ? CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                formatDescription,
                parameterSetIndex: 0,
                parameterSetPointerOut: nil,
                parameterSetSizeOut: nil,
                parameterSetCountOut: &count,
                nalUnitHeaderLengthOut: nil
            )
            : CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                formatDescription,
                parameterSetIndex: 0,
                parameterSetPointerOut: nil,
                parameterSetSizeOut: nil,
                parameterSetCountOut: &count,
                nalUnitHeaderLengthOut: nil
            )
        guard countStatus == noErr else { return nil }

        var output = Data()
        for index in 0..<count {
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            let status = isHEVC
                ? CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                    formatDescription,
                    parameterSetIndex: index,
                    parameterSetPointerOut: &pointer,
                    parameterSetSizeOut: &size,
                    parameterSetCountOut: nil,
                    nalUnitHeaderLengthOut: nil
                )
                : CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                    formatDescription,
                    parameterSetIndex: index,
                    parameterSetPointerOut: &pointer,
                    parameterSetSizeOut: &size,
                    parameterSetCountOut: nil,
                    nalUnitHeaderLengthOut: nil
                )
            guard status == noErr, let pointer else { return nil }

            output.append(startCode)
            output.append(pointer, count: size)
        }
        return output
    }

    /// Length prefix size announced by the format description.
    public static func nalLengthSize(of formatDescription: CMFormatDescription) -> Int {
        var nalLength: Int32 = 4
        switch formatDescription.mediaSubType {
        case .h264:
            _ = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                formatDescription,
                parameterSetIndex: 0,
                parameterSetPointerOut: nil,
                parameterSetSizeOut: nil,
                parameterSetCountOut: nil,
                nalUnitHeaderLengthOut: &nalLength
            )
        case .hevc:
            _ = CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                formatDescription,
                parameterSetIndex: 0,
                parameterSetPointerOut: nil,
                parameterSetSizeOut: nil,
                parameterSetCountOut: nil,
                nalUnitHeaderLengthOut: &nalLength
            )
        default:
            break
        }
        return Int(nalLength)
    }
}
