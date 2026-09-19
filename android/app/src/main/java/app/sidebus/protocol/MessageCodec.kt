package app.sidebus.protocol

import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.UUID

class ProtocolException(message: String) : Exception(message)

/**
 * Encoding and decoding of the wire format. Source of truth: `protocol/PROTOCOL.md`.
 *
 * Everything is little endian, except the NAL unit length prefixes, which belong to the
 * video format rather than to the protocol.
 */
object MessageCodec {
    const val MAGIC = 0x5B
    const val HEADER_SIZE = 8
    const val MAX_PAYLOAD_LENGTH = 8 * 1024 * 1024
    const val MAX_STRING_LENGTH = 255

    fun encode(message: Message): ByteArray {
        val payload = ByteArrayOutputStream()
        var flags = 0

        when (message) {
            is Message.Hello -> {
                payload.u16(message.version)
                payload.string(message.name)
                payload.uuid(message.uuid)
            }

            is Message.DeviceInfo -> {
                payload.u16(message.width)
                payload.u16(message.height)
                payload.u16(message.density)
                payload.u8(message.codecs)
                payload.string(message.name)
                payload.uuid(message.uuid)
            }

            is Message.DisplayConfig -> {
                payload.u16(message.width)
                payload.u16(message.height)
                payload.u8(message.fps)
                payload.u8(message.codec)
            }

            is Message.VideoConfig -> payload.write(message.parameterSets)

            is Message.VideoFrame -> {
                if (message.isKeyframe) flags = flags or 0x0001
                payload.u64(message.timestamp)
                payload.write(message.data)
            }

            is Message.InputEvent -> {
                payload.u8(message.kind)
                payload.f32(message.x)
                payload.f32(message.y)
                payload.u8(message.button)
                payload.u64(message.timestamp)
            }

            is Message.Ping -> payload.u64(message.timestamp)
            is Message.Pong -> payload.u64(message.timestamp)
            is Message.KeyframeRequest -> Unit
            is Message.Stats -> {
                payload.u32(message.received)
                payload.u32(message.dropped)
                payload.u16(message.windowMilliseconds)
            }

            is Message.Bye -> payload.u8(message.reason)
            is Message.PairRequest -> payload.u32(message.code)
            is Message.PairResult -> payload.u8(if (message.accepted) 1 else 0)

            is Message.CameraList -> {
                payload.u8(message.cameras.size.coerceAtMost(255))
                for (camera in message.cameras.take(255)) {
                    payload.u8(camera.id)
                    payload.u8(camera.facing)
                    payload.string(camera.label)
                }
            }

            is Message.CameraStart -> {
                payload.u8(message.id)
                payload.u16(message.width)
                payload.u16(message.height)
                payload.u8(message.fps)
                payload.u8(message.codec)
            }

            is Message.CameraConfig -> {
                payload.u16(message.width)
                payload.u16(message.height)
                payload.u8(message.codec)
                payload.u8(message.rotation)
                payload.write(message.parameterSets)
            }

            is Message.CameraFrame -> {
                if (message.isKeyframe) flags = flags or 0x0001
                payload.u64(message.timestamp)
                payload.write(message.data)
            }

            is Message.CameraStop -> Unit

            is Message.VideoStop -> Unit

            is Message.Unknown -> {
                flags = message.flags
                payload.write(message.payload)
            }
        }

        val body = payload.toByteArray()
        return ByteBuffer.allocate(HEADER_SIZE + body.size)
            .order(ByteOrder.LITTLE_ENDIAN)
            .put(MAGIC.toByte())
            .put(message.type.toByte())
            .putShort(flags.toShort())
            .putInt(body.size)
            .put(body)
            .array()
    }

    /** Decodes the payload of a message whose header has already been read. */
    fun decodePayload(type: Int, flags: Int, payload: ByteArray): Message =
        decodePayload(type, flags, payload, 0, payload.size)

    /**
     * The same, without demanding that the payload own an array: it is read in place in the
     * receive buffer. A video frame is copied once only, when building the array that goes to
     * the decoder.
     */
    fun decodePayload(type: Int, flags: Int, source: ByteArray, offset: Int, length: Int): Message {
        val reader = ByteReader(source, offset, offset + length)
        return when (type) {
            MessageType.HELLO -> Message.Hello(reader.u16(), reader.string(), reader.uuid())

            MessageType.DEVICE_INFO -> Message.DeviceInfo(
                width = reader.u16(),
                height = reader.u16(),
                density = reader.u16(),
                codecs = reader.u8(),
                name = reader.string(),
                uuid = reader.uuid(),
            )

            MessageType.DISPLAY_CONFIG -> Message.DisplayConfig(
                width = reader.u16(),
                height = reader.u16(),
                fps = reader.u8(),
                codec = reader.u8(),
            )

            MessageType.VIDEO_CONFIG -> Message.VideoConfig(reader.rest())

            MessageType.VIDEO_FRAME -> Message.VideoFrame(
                timestamp = reader.u64(),
                isKeyframe = (flags and 0x0001) != 0,
                data = reader.rest(),
            )

            MessageType.INPUT_EVENT -> Message.InputEvent(
                kind = reader.u8(),
                // Out of range coordinates are clamped, without error.
                x = reader.f32().coerceIn(0f, 1f),
                y = reader.f32().coerceIn(0f, 1f),
                button = reader.u8(),
                timestamp = reader.u64(),
            )

            MessageType.PING -> Message.Ping(reader.u64())
            MessageType.PONG -> Message.Pong(reader.u64())
            MessageType.KEYFRAME_REQ -> Message.KeyframeRequest
            MessageType.STATS -> Message.Stats(reader.u32(), reader.u32(), reader.u16())
            MessageType.BYE -> Message.Bye(reader.u8())
            MessageType.PAIR_REQUEST -> Message.PairRequest(reader.u32())
            // Any value other than 1 counts as a refusal: a future version adding a detailed
            // refusal code must not read as an acceptance.
            MessageType.PAIR_RESULT -> Message.PairResult(reader.u8() == 1)

            MessageType.CAMERA_LIST -> {
                val count = reader.u8()
                val cameras = ArrayList<CameraDescription>(count)
                repeat(count) {
                    cameras.add(CameraDescription(reader.u8(), reader.u8(), reader.string()))
                }
                Message.CameraList(cameras)
            }

            MessageType.CAMERA_START -> Message.CameraStart(
                id = reader.u8(),
                width = reader.u16(),
                height = reader.u16(),
                fps = reader.u8(),
                codec = reader.u8(),
            )

            MessageType.CAMERA_CONFIG -> Message.CameraConfig(
                width = reader.u16(),
                height = reader.u16(),
                codec = reader.u8(),
                rotation = reader.u8(),
                parameterSets = reader.rest(),
            )

            MessageType.CAMERA_FRAME -> Message.CameraFrame(
                timestamp = reader.u64(),
                isKeyframe = (flags and 0x0001) != 0,
                data = reader.rest(),
            )

            MessageType.CAMERA_STOP -> Message.CameraStop
            MessageType.VIDEO_STOP -> Message.VideoStop
            else -> Message.Unknown(type, flags, source.copyOfRange(offset, offset + length))
        }
    }

    // MARK: writing

    private fun ByteArrayOutputStream.u8(value: Int) = write(value and 0xFF)

    private fun ByteArrayOutputStream.u16(value: Int) {
        write(value and 0xFF)
        write((value ushr 8) and 0xFF)
    }

    private fun ByteArrayOutputStream.u32(value: Int) {
        for (shift in 0 until 4) write((value ushr (8 * shift)) and 0xFF)
    }

    private fun ByteArrayOutputStream.u64(value: Long) {
        for (shift in 0 until 8) write(((value ushr (8 * shift)) and 0xFF).toInt())
    }

    private fun ByteArrayOutputStream.f32(value: Float) = u32(java.lang.Float.floatToRawIntBits(value))

    /** 16 bit length then UTF-8, truncated on a character boundary. */
    private fun ByteArrayOutputStream.string(value: String) {
        var text = value
        var bytes = text.toByteArray(Charsets.UTF_8)
        while (bytes.size > MAX_STRING_LENGTH) {
            text = text.substring(0, text.length - 1)
            bytes = text.toByteArray(Charsets.UTF_8)
        }
        u16(bytes.size)
        write(bytes)
    }

    private fun ByteArrayOutputStream.uuid(value: UUID) {
        val buffer = ByteBuffer.allocate(16).order(ByteOrder.BIG_ENDIAN)
        buffer.putLong(value.mostSignificantBits)
        buffer.putLong(value.leastSignificantBits)
        write(buffer.array())
    }
}

/** Little endian reading, bounded, over a slice of an array. */
private class ByteReader(
    private val data: ByteArray,
    private var offset: Int = 0,
    private val end: Int = data.size,
) {
    private fun take(count: Int): Int {
        if (offset + count > end) {
            throw ProtocolException("truncated payload at offset $offset")
        }
        val start = offset
        offset += count
        return start
    }

    fun u8(): Int = data[take(1)].toInt() and 0xFF

    fun u16(): Int {
        val start = take(2)
        return (data[start].toInt() and 0xFF) or ((data[start + 1].toInt() and 0xFF) shl 8)
    }

    fun u32(): Int {
        val start = take(4)
        var value = 0
        for (index in 0 until 4) value = value or ((data[start + index].toInt() and 0xFF) shl (8 * index))
        return value
    }

    fun u64(): Long {
        val start = take(8)
        var value = 0L
        for (index in 0 until 8) value = value or ((data[start + index].toLong() and 0xFF) shl (8 * index))
        return value
    }

    fun f32(): Float = java.lang.Float.intBitsToFloat(u32())

    fun string(): String {
        val length = u16()
        val start = take(length)
        return String(data, start, length, Charsets.UTF_8)
    }

    fun uuid(): UUID {
        val start = take(16)
        val buffer = ByteBuffer.wrap(data, start, 16).order(ByteOrder.BIG_ENDIAN)
        return UUID(buffer.long, buffer.long)
    }

    fun rest(): ByteArray = data.copyOfRange(offset, end).also { offset = end }
}

/**
 * Accumulates received bytes and yields complete messages.
 *
 * The buffer is read and written by moving indices, never by copying what is already there.
 * The naive version, which grew the array on every packet, copied everything pending each
 * time: a video frame arriving in several pieces paid for as many full copies.
 */
class MessageDecoder(initialCapacity: Int = 256 * 1024) {
    private var buffer = ByteArray(initialCapacity)
    private var readOffset = 0
    private var writeOffset = 0

    /** Reads straight from the socket into the buffer, with no intermediate array. */
    fun readFrom(input: java.io.InputStream): Int {
        ensureWritable(READ_CHUNK)
        val read = input.read(buffer, writeOffset, buffer.size - writeOffset)
        if (read > 0) writeOffset += read
        return read
    }

    fun append(data: ByteArray, count: Int = data.size) {
        ensureWritable(count)
        data.copyInto(buffer, writeOffset, 0, count)
        writeOffset += count
    }

    /** The next complete message, or `null` while bytes are still missing. */
    fun next(): Message? {
        val available = writeOffset - readOffset
        if (available < MessageCodec.HEADER_SIZE) return null

        val magic = buffer[readOffset].toInt() and 0xFF
        if (magic != MessageCodec.MAGIC) {
            throw ProtocolException("octet magique invalide : 0x%02X".format(magic))
        }
        val type = buffer[readOffset + 1].toInt() and 0xFF
        val flags = (buffer[readOffset + 2].toInt() and 0xFF) or
            ((buffer[readOffset + 3].toInt() and 0xFF) shl 8)
        var length = 0
        for (index in 0 until 4) {
            length = length or ((buffer[readOffset + 4 + index].toInt() and 0xFF) shl (8 * index))
        }

        if (length < 0 || length > MessageCodec.MAX_PAYLOAD_LENGTH) {
            throw ProtocolException("payload of $length bytes, over the limit")
        }

        val total = MessageCodec.HEADER_SIZE + length
        if (available < total) {
            // Reserve room for the whole message: the next read completes it in one go, with
            // no reallocation midway.
            ensureWritable(total - available)
            return null
        }

        val message = MessageCodec.decodePayload(
            type,
            flags,
            buffer,
            readOffset + MessageCodec.HEADER_SIZE,
            length,
        )
        readOffset += total
        if (readOffset == writeOffset) {
            readOffset = 0
            writeOffset = 0
        }
        return message
    }

    private fun ensureWritable(count: Int) {
        if (buffer.size - writeOffset >= count) return

        val used = writeOffset - readOffset
        if (used + count <= buffer.size) {
            // Compacting is enough: move what is pending back to the start.
            buffer.copyInto(buffer, 0, readOffset, writeOffset)
        } else {
            var capacity = buffer.size
            while (capacity - used < count) capacity *= 2
            val grown = ByteArray(capacity)
            buffer.copyInto(grown, 0, readOffset, writeOffset)
            buffer = grown
        }
        readOffset = 0
        writeOffset = used
    }

    private companion object {
        const val READ_CHUNK = 64 * 1024
    }
}
