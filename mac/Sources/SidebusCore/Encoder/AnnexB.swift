import CoreMedia
import Foundation

/// Conversion du format de sortie de VideoToolbox vers Annex B.
///
/// VideoToolbox produit des NAL units préfixées par leur longueur (format AVCC). Le fil
/// Sidebus et `MediaCodec` attendent de l'Annex B, c'est à dire des NAL units séparées par
/// le code de départ `00 00 00 01`. Voir `protocol/PROTOCOL.md`, messages VIDEO_CONFIG et
/// VIDEO_FRAME.
public enum AnnexB {
    public static let startCode = Data([0x00, 0x00, 0x00, 0x01])

    public enum Error: Swift.Error, CustomStringConvertible, Sendable {
        case invalidLengthSize(Int)
        case truncated(offset: Int)

        public var description: String {
            switch self {
            case let .invalidLengthSize(size):
                return "taille de préfixe de NAL invalide : \(size)"
            case let .truncated(offset):
                return "flux AVCC tronqué à l'offset \(offset)"
            }
        }
    }

    /// Convertit un buffer AVCC en Annex B.
    ///
    /// - Parameter nalLengthSize: taille du préfixe de longueur, 1 à 4 octets,
    ///   annoncée par la description de format. Vaut 4 en pratique.
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

            // Le préfixe de longueur est en big endian, contrairement au reste du protocole.
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
    /// Le préfixe de longueur fait quatre octets, le code de départ aussi : il suffit donc
    /// de réécrire les quatre octets de longueur par `00 00 00 01`. Ça supprime une copie
    /// complète de chaque frame encodée.
    ///
    /// Les tailles de préfixe autres que quatre, jamais vues en sortie de VideoToolbox,
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

    /// Jeux de paramètres d'une description de format, concaténés en Annex B :
    /// SPS et PPS en H.264, VPS, SPS et PPS en HEVC.
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

    /// Taille du préfixe de longueur annoncée par la description de format.
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
