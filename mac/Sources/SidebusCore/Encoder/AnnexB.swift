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

    /// Splits an Annex B blob into its NAL units, dropping the start codes.
    ///
    /// Used on the receiving side: CoreMedia builds a format description from the parameter
    /// sets as separate buffers, not as one concatenated blob.
    public static func split(_ data: Data) -> [Data] {
        var units: [Data] = []
        var index = data.startIndex
        var unitStart: Int?

        while index < data.endIndex {
            let length = startCodeLength(in: data, at: index)
            if length > 0 {
                if let start = unitStart, index > start {
                    units.append(data.subdata(in: start..<index))
                }
                index += length
                unitStart = index
                continue
            }
            index += 1
        }
        if let start = unitStart, start < data.endIndex {
            units.append(data.subdata(in: start..<data.endIndex))
        }
        return units
    }

    /// Rewrites Annex B start codes as four byte length prefixes.
    ///
    /// Stays in place when every start code is four bytes wide, which costs nothing: both
    /// markers are the same size, so only those four bytes change.
    ///
    /// `MediaCodec` mixes both forms inside one frame, a four byte code in front and three
    /// byte ones between the NAL units that follow. A three byte code cannot be rewritten in
    /// place, since the prefix is one byte longer, so the buffer is rebuilt in that case.
    /// Ignoring those codes leaves them inside the payload, the preceding length comes out
    /// too long, and the decoder produces flat blocks of colour instead of a picture.
    public static func convertToLengthPrefixed(_ data: inout Data) {
        var boundaries: [(start: Int, codeLength: Int)] = []
        var index = data.startIndex
        while index < data.endIndex {
            let length = startCodeLength(in: data, at: index)
            if length > 0 {
                boundaries.append((index, length))
                index += length
                continue
            }
            index += 1
        }
        guard !boundaries.isEmpty else { return }

        if boundaries.allSatisfy({ $0.codeLength == 4 }) {
            for (position, boundary) in boundaries.enumerated() {
                let end = position + 1 < boundaries.count
                    ? boundaries[position + 1].start
                    : data.endIndex
                write(UInt32(end - boundary.start - 4), into: &data, at: boundary.start)
            }
            return
        }

        var rebuilt = Data()
        rebuilt.reserveCapacity(data.count + boundaries.count)
        for (position, boundary) in boundaries.enumerated() {
            let payloadStart = boundary.start + boundary.codeLength
            let payloadEnd = position + 1 < boundaries.count
                ? boundaries[position + 1].start
                : data.endIndex
            guard payloadEnd > payloadStart else { continue }

            let length = UInt32(payloadEnd - payloadStart)
            rebuilt.append(UInt8((length >> 24) & 0xFF))
            rebuilt.append(UInt8((length >> 16) & 0xFF))
            rebuilt.append(UInt8((length >> 8) & 0xFF))
            rebuilt.append(UInt8(length & 0xFF))
            rebuilt.append(data.subdata(in: payloadStart..<payloadEnd))
        }
        data = rebuilt
    }

    private static func write(_ value: UInt32, into data: inout Data, at index: Int) {
        data[index] = UInt8((value >> 24) & 0xFF)
        data[index + 1] = UInt8((value >> 16) & 0xFF)
        data[index + 2] = UInt8((value >> 8) & 0xFF)
        data[index + 3] = UInt8(value & 0xFF)
    }

    /// Length of the start code at `index`, or 0 when there is none. Both the three byte and
    /// the four byte forms exist in the wild.
    private static func startCodeLength(in data: Data, at index: Int) -> Int {
        guard index + 2 < data.endIndex else { return 0 }
        if data[index] == 0, data[index + 1] == 0 {
            if data[index + 2] == 1 { return 3 }
            if index + 3 < data.endIndex, data[index + 2] == 0, data[index + 3] == 1 { return 4 }
        }
        return 0
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
