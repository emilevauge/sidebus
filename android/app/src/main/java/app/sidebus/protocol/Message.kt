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
    const val CAMERA_LIST = 0x0E
    const val CAMERA_START = 0x0F
    const val CAMERA_CONFIG = 0x10
    const val CAMERA_FRAME = 0x11
    const val CAMERA_STOP = 0x12
    const val VIDEO_STOP = 0x13
}

/** Which way a camera points. See `protocol/PROTOCOL.md`, section 5.5. */
object CameraFacing {
    const val BACK = 0x00
    const val FRONT = 0x01
    const val EXTERNAL = 0x02
}

/** One camera the tablet is willing to share. */
data class CameraDescription(val id: Int, val facing: Int, val label: String)

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

    /** Cameras the tablet can share, sent unsolicited after DEVICE_INFO. */
    data class CameraList(val cameras: List<CameraDescription>) : Message() {
        override val type = MessageType.CAMERA_LIST
    }

    /** Asks the tablet to open a camera and start encoding it. */
    data class CameraStart(
        val id: Int,
        val width: Int,
        val height: Int,
        val fps: Int,
        val codec: Int,
    ) : Message() {
        override val type = MessageType.CAMERA_START
    }

    /**
     * What the tablet actually opened, with the codec parameter sets.
     *
     * [rotation] is the number of quarter turns clockwise the receiver applies to show the
     * picture upright. See `protocol/PROTOCOL.md`, section 5.6.
     */
    data class CameraConfig(
        val width: Int,
        val height: Int,
        val codec: Int,
        val rotation: Int,
        val parameterSets: ByteArray,
    ) : Message() {
        override val type = MessageType.CAMERA_CONFIG

        override fun equals(other: Any?) =
            other is CameraConfig && width == other.width && height == other.height &&
                codec == other.codec && rotation == other.rotation &&
                parameterSets.contentEquals(other.parameterSets)

        override fun hashCode() =
            (((width * 31 + height) * 31 + codec) * 31 + rotation) * 31 +
                parameterSets.contentHashCode()
    }

    /** One encoded camera frame, same shape as VIDEO_FRAME in the other direction. */
    data class CameraFrame(
        val timestamp: Long,
        val isKeyframe: Boolean,
        val data: ByteArray,
    ) : Message() {
        override val type = MessageType.CAMERA_FRAME

        override fun equals(other: Any?) =
            other is CameraFrame && timestamp == other.timestamp &&
                isKeyframe == other.isKeyframe && data.contentEquals(other.data)

        override fun hashCode() =
            (timestamp.hashCode() * 31 + isKeyframe.hashCode()) * 31 + data.contentHashCode()
    }

    object CameraStop : Message() {
        override val type = MessageType.CAMERA_STOP
    }

    /**
     * The Mac stops sharing its screen but keeps the link, which is what happens when only a
     * camera is still wanted. See `protocol/PROTOCOL.md`, section 4.18.
     */
    object VideoStop : Message() {
        override val type = MessageType.VIDEO_STOP
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
