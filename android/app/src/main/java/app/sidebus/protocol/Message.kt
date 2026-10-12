package app.sidebus.protocol

import java.util.UUID

/** Protocol message types. See `protocol/PROTOCOL.md`, section 4. */
object MessageType {
    const val HELLO = 0x01
    const val DEVICE_INFO = 0x02
    const val DISPLAY_CONFIG = 0x03
    const val VIDEO_CONFIG = 0x04
    const val VIDEO_FRAME = 0x05
    const val INPUT_EVENT = 0x06
    const val PING = 0x07
    const val PONG = 0x08
    const val KEYFRAME_REQ = 0x09
    const val STATS = 0x0A
    const val BYE = 0x0B
    const val PAIR_REQUEST = 0x0C
    const val PAIR_RESULT = 0x0D
    const val CALL_ACCESS = 0x0E
    const val CALL_GRANT = 0x0F
    const val CALL_STATUS = 0x10
    const val CALL_START = 0x11
    const val CALL_STOP = 0x12
    const val CALL_AUDIO = 0x13
    const val CONTACTS_REQ = 0x14
    const val CONTACTS = 0x15
    const val CALLER_ID = 0x16
}

/** CALL_GRANT status, `protocol/PROTOCOL.md` 10.2. */
object CallGrantStatus {
    const val REFUSED = 0
    const val GRANTED = 1
    const val WAITING = 2
}

object Codec {
    const val H264 = 0x01
    const val HEVC = 0x02
}

object InputEventKind {
    const val DOWN = 0x00
    const val MOVE = 0x01
    const val UP = 0x02
}

object MouseButton {
    const val LEFT = 0x00
    const val RIGHT = 0x01
    const val MIDDLE = 0x02
}

object ByeReason {
    const val NORMAL = 0x00
    const val TRANSPORT_SWITCH = 0x01
    const val ERROR = 0x02
}

/** A decoded protocol message. */
sealed class Message {
    abstract val type: Int

    data class Hello(val version: Int, val name: String, val uuid: UUID) : Message() {
        override val type = MessageType.HELLO
    }

    data class DeviceInfo(
        val width: Int,
        val height: Int,
        val density: Int,
        val codecs: Int,
        val name: String,
        /** Persistent device identifier, the key to arbitrating between transports. */
        val uuid: UUID,
    ) : Message() {
        override val type = MessageType.DEVICE_INFO
    }

    data class DisplayConfig(
        val width: Int,
        val height: Int,
        val fps: Int,
        val codec: Int,
    ) : Message() {
        override val type = MessageType.DISPLAY_CONFIG
    }

    data class VideoConfig(val parameterSets: ByteArray) : Message() {
        override val type = MessageType.VIDEO_CONFIG

        override fun equals(other: Any?) =
            other is VideoConfig && parameterSets.contentEquals(other.parameterSets)

        override fun hashCode() = parameterSets.contentHashCode()
    }

    data class VideoFrame(
        val timestamp: Long,
        val isKeyframe: Boolean,
        val data: ByteArray,
    ) : Message() {
        override val type = MessageType.VIDEO_FRAME

        override fun equals(other: Any?) =
            other is VideoFrame &&
                timestamp == other.timestamp &&
                isKeyframe == other.isKeyframe &&
                data.contentEquals(other.data)

        override fun hashCode() =
            (timestamp.hashCode() * 31 + isKeyframe.hashCode()) * 31 + data.contentHashCode()
    }

    data class InputEvent(
        val kind: Int,
        val x: Float,
        val y: Float,
        val button: Int,
        val timestamp: Long,
    ) : Message() {
        override val type = MessageType.INPUT_EVENT
    }

    data class Ping(val timestamp: Long) : Message() {
        override val type = MessageType.PING
    }

    data class Pong(val timestamp: Long) : Message() {
        override val type = MessageType.PONG
    }

    object KeyframeRequest : Message() {
        override val type = MessageType.KEYFRAME_REQ
    }

    data class Stats(
        val received: Int,
        val dropped: Int,
        val windowMilliseconds: Int,
    ) : Message() {
        override val type = MessageType.STATS
    }

    data class Bye(val reason: Int) : Message() {
        override val type = MessageType.BYE
    }

    /**
     * Pairing confirmation request, sent by the Mac after DEVICE_INFO when it did not already
     * know the certificate fingerprint. See `protocol/PROTOCOL.md` 4.12.
     */
    data class PairRequest(val code: Int) : Message() {
        override val type = MessageType.PAIR_REQUEST
    }

    /** The tablet's answer to PAIR_REQUEST. */
    data class PairResult(val accepted: Boolean) : Message() {
        override val type = MessageType.PAIR_RESULT
    }

    /** Phone calls, `protocol/PROTOCOL.md` section 10. */
    class CallAccess(val token: ByteArray) : Message() {
        override val type = MessageType.CALL_ACCESS
    }

    class CallGrant(val status: Int, val token: ByteArray) : Message() {
        override val type = MessageType.CALL_GRANT
    }

    /** Bit 0: the audio helper runs. Bit 1: contacts are readable. */
    data class CallStatus(val flags: Int) : Message() {
        override val type = MessageType.CALL_STATUS
    }

    object CallStart : Message() {
        override val type = MessageType.CALL_START
    }

    object CallStop : Message() {
        override val type = MessageType.CALL_STOP
    }

    /** 16 kHz mono 16 bit little endian PCM. */
    class CallAudio(val pcm: ByteArray) : Message() {
        override val type = MessageType.CALL_AUDIO
    }

    object ContactsRequest : Message() {
        override val type = MessageType.CONTACTS_REQ
    }

    /** One line per number: name, tab, number, tab, starred as 0 or 1. */
    class Contacts(val entries: ByteArray) : Message() {
        override val type = MessageType.CONTACTS
    }

    /** The ringing call's caller as the phone's call screen shows it: title, newline, text. */
    class CallerId(val caller: ByteArray) : Message() {
        override val type = MessageType.CALLER_ID
    }

    /**
     * A message of a type this version does not know. Kept so that it can be skipped cleanly
     * rather than closing the connection.
     */
    data class Unknown(
        override val type: Int,
        val flags: Int,
        val payload: ByteArray,
    ) : Message() {
        override fun equals(other: Any?) =
            other is Unknown &&
                type == other.type &&
                flags == other.flags &&
                payload.contentEquals(other.payload)

        override fun hashCode() = (type * 31 + flags) * 31 + payload.contentHashCode()
    }
}
