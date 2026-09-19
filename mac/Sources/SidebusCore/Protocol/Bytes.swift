import Foundation

/// Little endian writing. See `protocol/PROTOCOL.md`, section 3.
struct ByteWriter {
    private(set) var data = Data()

    mutating func u8(_ value: UInt8) {
        data.append(value)
    }

    mutating func u16(_ value: UInt16) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }

    mutating func u32(_ value: UInt32) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }

    mutating func u64(_ value: UInt64) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }

    mutating func f32(_ value: Float) {
        u32(value.bitPattern)
    }

    mutating func bytes(_ value: Data) {
        data.append(value)
    }

    /// 16 bit length then UTF-8. Truncated on a character boundary when the string
    /// goes past 255 bytes.
    mutating func string(_ value: String) {
        var utf8 = Array(value.utf8)
        if utf8.count > MessageCodec.maxStringLength {
            var truncated = value
            while truncated.utf8.count > MessageCodec.maxStringLength {
                truncated.removeLast()
            }
            utf8 = Array(truncated.utf8)
        }
        u16(UInt16(utf8.count))
        data.append(contentsOf: utf8)
    }

    /// UUID as 16 bytes, RFC 4122 order, the one of the text form.
    mutating func uuid(_ value: UUID) {
        let bytes = value.uuid
        data.append(contentsOf: [
            bytes.0, bytes.1, bytes.2, bytes.3, bytes.4, bytes.5, bytes.6, bytes.7,
            bytes.8, bytes.9, bytes.10, bytes.11, bytes.12, bytes.13, bytes.14, bytes.15,
        ])
    }
}

/// Little endian reading, bounded.
struct ByteReader {
    struct OutOfBounds: Error {}

    private let data: Data
    private var offset: Int

    init(_ data: Data) {
        self.data = data
        offset = data.startIndex
    }

    private mutating func take(_ count: Int) throws -> Data {
        guard data.distance(from: offset, to: data.endIndex) >= count else {
            throw OutOfBounds()
        }
        let end = data.index(offset, offsetBy: count)
        defer { offset = end }
        return data[offset..<end]
    }

    mutating func u8() throws -> UInt8 {
        try take(1).first!
    }

    mutating func u16() throws -> UInt16 {
        var value: UInt16 = 0
        for (index, byte) in try take(2).enumerated() {
            value |= UInt16(byte) << (8 * index)
        }
        return value
    }

    mutating func u32() throws -> UInt32 {
        var value: UInt32 = 0
        let slice = try take(4)
        for (index, byte) in slice.enumerated() {
            value |= UInt32(byte) << (8 * index)
        }
        return value
    }

    mutating func u64() throws -> UInt64 {
        var value: UInt64 = 0
        let slice = try take(8)
        for (index, byte) in slice.enumerated() {
            value |= UInt64(byte) << (8 * index)
        }
        return value
    }

    mutating func f32() throws -> Float {
        Float(bitPattern: try u32())
    }

    mutating func string() throws -> String {
        let count = Int(try u16())
        let bytes = try take(count)
        return String(decoding: bytes, as: UTF8.self)
    }

    mutating func uuid() throws -> UUID {
        let bytes = Array(try take(16))
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    /// Everything left to read.
    mutating func rest() -> Data {
        let remaining = data[offset...]
        offset = data.endIndex
        return Data(remaining)
    }
}
