import Foundation

/// Protocol message types. See `protocol/PROTOCOL.md`, section 4.
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
    case pairRequest = 0x0C
    case pairResult = 0x0D
    case callAccess = 0x0E
    case callGrant = 0x0F
    case callStatus = 0x10
    case callStart = 0x11
    case callStop = 0x12
    case callAudio = 0x13
    case contactsRequest = 0x14
    case contacts = 0x15
    case callerID = 0x16
}

/// CALL_GRANT status, `protocol/PROTOCOL.md` 10.2.
public enum CallGrantStatus: UInt8, Sendable {
    case refused = 0
    case granted = 1
    case waiting = 2
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

/// A decoded protocol message.
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

    /// Pairing confirmation request, sent by the Mac after DEVICE_INFO when it did not
    /// already know the certificate fingerprint. See `protocol/PROTOCOL.md` 4.12.
    case pairRequest(code: UInt32)

    /// The tablet's answer to PAIR_REQUEST.
    case pairResult(accepted: Bool)

    /// Phone calls, `protocol/PROTOCOL.md` section 10.
    case callAccess(token: Data)
    case callGrant(status: CallGrantStatus, token: Data)
    /// Bit 0: the audio helper runs. Bit 1: contacts are readable.
    case callStatus(flags: UInt8)
    case callStart
    case callStop
    /// 16 kHz mono 16 bit little endian PCM.
    case callAudio(Data)
    case contactsRequest
    /// One line per number: name, tab, number, tab, starred as 0 or 1.
    case contacts(Data)
    /// The ringing call's caller as the phone's call screen shows it: title, newline, text.
    case callerID(Data)

    /// A message of a type this version does not know. Kept so that it can be skipped
    /// cleanly rather than closing the connection.
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
        case .pairRequest: return MessageType.pairRequest.rawValue
        case .pairResult: return MessageType.pairResult.rawValue
        case .callAccess: return MessageType.callAccess.rawValue
        case .callGrant: return MessageType.callGrant.rawValue
        case .callStatus: return MessageType.callStatus.rawValue
        case .callStart: return MessageType.callStart.rawValue
        case .callStop: return MessageType.callStop.rawValue
        case .callAudio: return MessageType.callAudio.rawValue
        case .contactsRequest: return MessageType.contactsRequest.rawValue
        case .contacts: return MessageType.contacts.rawValue
        case .callerID: return MessageType.callerID.rawValue
        case let .unknown(type, _, _): return type
        }
    }
}
