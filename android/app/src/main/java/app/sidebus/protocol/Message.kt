package app.sidebus.protocol

import java.util.UUID

/** Types de messages du protocole. Voir `protocol/PROTOCOL.md`, section 4. */
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

/** Un message du protocole, décodé. */
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
        /** Identifiant persistant de l'appareil, clé de l'arbitrage entre transports. */
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
     * Demande de confirmation d'appairage, envoyée par le Mac après DEVICE_INFO quand il ne
     * connaissait pas l'empreinte du certificat. Voir `protocol/PROTOCOL.md` 4.12.
     */
    data class PairRequest(val code: Int) : Message() {
        override val type = MessageType.PAIR_REQUEST
    }

    /** Réponse de la tablette à PAIR_REQUEST. */
    data class PairResult(val accepted: Boolean) : Message() {
        override val type = MessageType.PAIR_RESULT
    }

    /**
     * Message d'un type que cette version ne connaît pas. Conservé pour pouvoir l'ignorer
     * proprement plutôt que de fermer la connexion.
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
