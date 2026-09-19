import Foundation

public enum ProtocolError: Error, CustomStringConvertible, Sendable, Equatable {
    case badMagic(UInt8)
    case payloadTooLarge(UInt32)
    case malformedPayload(MessageType)
    case truncatedPayload(MessageType)
    case stringTooLong(Int)
    case unknownEnumValue(String, UInt8)

    public var description: String {
        switch self {
        case let .badMagic(value):
            return String(format: "invalid magic byte: 0x%02X", value)
        case let .payloadTooLarge(length):
            return "payload of \(length) bytes, past the bound"
        case let .malformedPayload(type):
            return "malformed payload for \(type)"
        case let .truncatedPayload(type):
            return "truncated payload for \(type)"
        case let .stringTooLong(count):
            return "string of \(count) bytes, past 255"
        case let .unknownEnumValue(name, value):
            return String(format: "unknown \(name) value: 0x%02X", value)
        }
    }
}

/// Encoding and decoding of the wire format. Source of truth: `protocol/PROTOCOL.md`.
///
/// Everything is little endian, except the NAL unit length prefixes, which belong to the
/// video format rather than to the protocol.
public enum MessageCodec {
    public static let magic: UInt8 = 0x5B
    public static let headerSize = 8
    public static let maxPayloadLength: UInt32 = 8 * 1024 * 1024
    public static let maxStringLength = 255

    // MARK: - Encoding

    public static func encode(_ message: Message) -> Data {
        var payload = ByteWriter()
        var flags: UInt16 = 0

        switch message {
        case let .hello(version, name, uuid):
            payload.u16(version)
            payload.string(name)
            payload.uuid(uuid)

        case let .deviceInfo(width, height, density, codecs, name, uuid):
            payload.u16(width)
            payload.u16(height)
            payload.u16(density)
            payload.u8(codecs)
            payload.string(name)
            payload.uuid(uuid)

        case let .displayConfig(width, height, fps, codec):
            payload.u16(width)
            payload.u16(height)
            payload.u8(fps)
            payload.u8(codec.rawValue)

        case let .videoConfig(parameterSets):
            payload.bytes(parameterSets)

        case let .videoFrame(timestamp, isKeyframe, data):
            if isKeyframe { flags |= 0x0001 }
            payload.u64(timestamp)
            payload.bytes(data)

        case let .inputEvent(kind, x, y, button, timestamp):
            payload.u8(kind.rawValue)
            payload.f32(x)
            payload.f32(y)
            payload.u8(button.rawValue)
            payload.u64(timestamp)

        case let .ping(timestamp), let .pong(timestamp):
            payload.u64(timestamp)

        case .keyframeRequest:
            break

        case let .stats(received, dropped, window):
            payload.u32(received)
            payload.u32(dropped)
            payload.u16(window)

        case let .bye(reason):
            payload.u8(reason.rawValue)

        case let .pairRequest(code):
            payload.u32(code)

        case let .pairResult(accepted):
            payload.u8(accepted ? 1 : 0)

        case let .cameraList(cameras):
            payload.u8(UInt8(min(cameras.count, 255)))
            for camera in cameras.prefix(255) {
                payload.u8(camera.id)
                payload.u8(camera.facing.rawValue)
                payload.string(camera.label)
            }

        case let .cameraStart(id, width, height, fps, codec):
            payload.u8(id)
            payload.u16(width)
            payload.u16(height)
            payload.u8(fps)
            payload.u8(codec.rawValue)

        case let .cameraConfig(width, height, codec, rotation, parameterSets):
            payload.u16(width)
            payload.u16(height)
            payload.u8(codec.rawValue)
            payload.u8(rotation)
            payload.bytes(parameterSets)

        case let .cameraFrame(timestamp, isKeyframe, data):
            if isKeyframe { flags |= 0x0001 }
            payload.u64(timestamp)
            payload.bytes(data)

        case .cameraStop, .videoStop:
            break

        case let .unknown(_, unknownFlags, data):
            flags = unknownFlags
            payload.bytes(data)
        }

        var out = ByteWriter()
        out.u8(magic)
        out.u8(message.type)
        out.u16(flags)
        out.u32(UInt32(payload.data.count))
        out.bytes(payload.data)
        return out.data
    }

    // MARK: - Decoding

    /// Decodes the payload of a message whose header has already been read.
    public static func decodePayload(
        type rawType: UInt8,
        flags: UInt16,
        payload: Data
    ) throws -> Message {
        guard let type = MessageType(rawValue: rawType) else {
            return .unknown(type: rawType, flags: flags, payload: payload)
        }

        var reader = ByteReader(payload)

        do {
            switch type {
            case .hello:
                let version = try reader.u16()
                let name = try reader.string()
                let uuid = try reader.uuid()
                return .hello(version: version, name: name, uuid: uuid)

            case .deviceInfo:
                let width = try reader.u16()
                let height = try reader.u16()
                let density = try reader.u16()
                let codecs = try reader.u8()
                let name = try reader.string()
                let uuid = try reader.uuid()
                return .deviceInfo(
                    width: width,
                    height: height,
                    density: density,
                    codecs: codecs,
                    name: name,
                    uuid: uuid
                )

            case .displayConfig:
                let width = try reader.u16()
                let height = try reader.u16()
                let fps = try reader.u8()
                let rawCodec = try reader.u8()
                guard let codec = Codec(rawValue: rawCodec) else {
                    throw ProtocolError.unknownEnumValue("codec", rawCodec)
                }
                return .displayConfig(width: width, height: height, fps: fps, codec: codec)

            case .videoConfig:
                return .videoConfig(parameterSets: reader.rest())

            case .videoFrame:
                let timestamp = try reader.u64()
                return .videoFrame(
                    timestamp: timestamp,
                    isKeyframe: flags & 0x0001 != 0,
                    data: reader.rest()
                )

            case .inputEvent:
                let rawKind = try reader.u8()
                guard let kind = InputEventKind(rawValue: rawKind) else {
                    throw ProtocolError.unknownEnumValue("event kind", rawKind)
                }
                let x = try reader.f32()
                let y = try reader.f32()
                let rawButton = try reader.u8()
                guard let button = MouseButton(rawValue: rawButton) else {
                    throw ProtocolError.unknownEnumValue("button", rawButton)
                }
                let timestamp = try reader.u64()
                // Out of range coordinates are clamped, without error.
                return .inputEvent(
                    kind: kind,
                    x: min(max(x, 0), 1),
                    y: min(max(y, 0), 1),
                    button: button,
                    timestamp: timestamp
                )

            case .ping:
                return .ping(timestamp: try reader.u64())

            case .pong:
                return .pong(timestamp: try reader.u64())

            case .keyframeRequest:
                return .keyframeRequest

            case .stats:
                let received = try reader.u32()
                let dropped = try reader.u32()
                let window = try reader.u16()
                return .stats(received: received, dropped: dropped, windowMilliseconds: window)

            case .bye:
                let rawReason = try reader.u8()
                guard let reason = ByeReason(rawValue: rawReason) else {
                    throw ProtocolError.unknownEnumValue("BYE reason", rawReason)
                }
                return .bye(reason: reason)

            case .pairRequest:
                return .pairRequest(code: try reader.u32())

            case .pairResult:
                // Any value other than 1 counts as a refusal: a future version adding a
                // detailed refusal code must not read as an acceptance.
                return .pairResult(accepted: try reader.u8() == 1)

            case .cameraList:
                let count = try reader.u8()
                var cameras: [CameraDescription] = []
                for _ in 0..<count {
                    let id = try reader.u8()
                    let rawFacing = try reader.u8()
                    guard let facing = CameraFacing(rawValue: rawFacing) else {
                        throw ProtocolError.unknownEnumValue("camera facing", rawFacing)
                    }
                    cameras.append(
                        CameraDescription(id: id, facing: facing, label: try reader.string())
                    )
                }
                return .cameraList(cameras)

            case .cameraStart:
                let id = try reader.u8()
                let width = try reader.u16()
                let height = try reader.u16()
                let fps = try reader.u8()
                let rawCodec = try reader.u8()
                guard let codec = Codec(rawValue: rawCodec) else {
                    throw ProtocolError.unknownEnumValue("codec", rawCodec)
                }
                return .cameraStart(id: id, width: width, height: height, fps: fps, codec: codec)

            case .cameraConfig:
                let width = try reader.u16()
                let height = try reader.u16()
                let rawCodec = try reader.u8()
                guard let codec = Codec(rawValue: rawCodec) else {
                    throw ProtocolError.unknownEnumValue("codec", rawCodec)
                }
                return .cameraConfig(
                    width: width,
                    height: height,
                    codec: codec,
                    rotation: try reader.u8(),
                    parameterSets: reader.rest()
                )

            case .cameraFrame:
                let timestamp = try reader.u64()
                return .cameraFrame(
                    timestamp: timestamp,
                    isKeyframe: flags & 0x0001 != 0,
                    data: reader.rest()
                )

            case .cameraStop:
                return .cameraStop

            case .videoStop:
                return .videoStop
            }
        } catch is ByteReader.OutOfBounds {
            throw ProtocolError.truncatedPayload(type)
        }
    }
}

/// Accumulates received bytes and yields complete messages.
public struct MessageDecoder: Sendable {
    private var buffer = Data()

    public init() {}

    public mutating func append(_ data: Data) {
        buffer.append(data)
    }

    /// Returns the next complete message, or `nil` when bytes are missing.
    public mutating func next() throws -> Message? {
        guard buffer.count >= MessageCodec.headerSize else { return nil }

        var reader = ByteReader(buffer)
        let magic = try reader.u8()
        guard magic == MessageCodec.magic else {
            throw ProtocolError.badMagic(magic)
        }
        let type = try reader.u8()
        let flags = try reader.u16()
        let length = try reader.u32()

        guard length <= MessageCodec.maxPayloadLength else {
            throw ProtocolError.payloadTooLarge(length)
        }

        let total = MessageCodec.headerSize + Int(length)
        guard buffer.count >= total else { return nil }

        let payload = buffer.subdata(in: (buffer.startIndex + MessageCodec.headerSize)..<(buffer.startIndex + total))
        buffer.removeFirst(total)

        return try MessageCodec.decodePayload(type: type, flags: flags, payload: payload)
    }
}
