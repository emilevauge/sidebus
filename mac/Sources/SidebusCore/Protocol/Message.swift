import Foundation

/// Types de messages du protocole. Voir `protocol/PROTOCOL.md`, section 4.
public enum MessageType: UInt8, Sendable, CaseIterable {
    case hello = 0x01
    case deviceInfo = 0x02
    case displayConfig = 0x03
    case videoConfig = 0x04
    case videoFrame = 0x05
    case inputEvent = 0x06
    case ping = 0x07
    case pong = 0x08
    case keyframeRequest = 0x09
    case stats = 0x0A
    case bye = 0x0B
}

public enum Codec: UInt8, Sendable {
    case h264 = 0x01
    case hevc = 0x02
}

public enum InputEventKind: UInt8, Sendable {
    case down = 0x00
    case move = 0x01
    case up = 0x02
}

public enum MouseButton: UInt8, Sendable {
    case left = 0x00
    case right = 0x01
    case middle = 0x02
}

public enum ByeReason: UInt8, Sendable {
    case normal = 0x00
    case transportSwitch = 0x01
    case error = 0x02
}

/// Un message du protocole, décodé.
public enum Message: Sendable, Equatable {
    case hello(version: UInt16, name: String, uuid: UUID)
    case deviceInfo(
        width: UInt16,
        height: UInt16,
        density: UInt16,
        codecs: UInt8,
        name: String,
        uuid: UUID
    )
    case displayConfig(width: UInt16, height: UInt16, fps: UInt8, codec: Codec)
    case videoConfig(parameterSets: Data)
    case videoFrame(timestamp: UInt64, isKeyframe: Bool, data: Data)
    case inputEvent(
        kind: InputEventKind,
        x: Float,
        y: Float,
        button: MouseButton,
        timestamp: UInt64
    )
    case ping(timestamp: UInt64)
    case pong(timestamp: UInt64)
    case keyframeRequest
    case stats(received: UInt32, dropped: UInt32, windowMilliseconds: UInt16)
    case bye(reason: ByeReason)

    /// Message d'un type que cette version ne connaît pas. Conservé pour pouvoir
    /// l'ignorer proprement plutôt que de fermer la connexion.
    case unknown(type: UInt8, flags: UInt16, payload: Data)

    public var type: UInt8 {
        switch self {
        case .hello: return MessageType.hello.rawValue
        case .deviceInfo: return MessageType.deviceInfo.rawValue
        case .displayConfig: return MessageType.displayConfig.rawValue
        case .videoConfig: return MessageType.videoConfig.rawValue
        case .videoFrame: return MessageType.videoFrame.rawValue
        case .inputEvent: return MessageType.inputEvent.rawValue
        case .ping: return MessageType.ping.rawValue
        case .pong: return MessageType.pong.rawValue
        case .keyframeRequest: return MessageType.keyframeRequest.rawValue
        case .stats: return MessageType.stats.rawValue
        case .bye: return MessageType.bye.rawValue
        case let .unknown(type, _, _): return type
        }
    }
}
