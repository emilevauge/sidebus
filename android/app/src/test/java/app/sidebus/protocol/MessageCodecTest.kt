package app.sidebus.protocol

import java.io.File
import java.util.UUID
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

/**
 * Same vectors as the Swift tests, same expectations. See
 * `protocol/testvectors/README.md`.
 */
class MessageCodecTest {

    private val vectors = File("../../protocol/testvectors")

    private fun vector(name: String): ByteArray = File(vectors, name).readBytes()

    /** Decodes the vector, compares with the expected message, re-encodes and compares bytes. */
    private fun check(name: String, expected: Message) {
        val bytes = vector(name)

        val decoder = MessageDecoder()
        decoder.append(bytes)
        val decoded = decoder.next()
        assertNotNull("$name: nothing decoded", decoded)
        assertEquals("$name: fields differ", expected, decoded)
        assertNull("$name : octets en trop", decoder.next())

        assertArrayEquals("$name: re-encoding differs", bytes, MessageCodec.encode(expected))
    }

    @Test
    fun hello() {
        check(
            "hello.bin",
            Message.Hello(
                version = 1,
                name = "MacBook d'Émile",
                uuid = UUID.fromString("550e8400-e29b-41d4-a716-446655440000"),
            ),
        )
    }

    @Test
    fun deviceInfo() {
        check(
            "device_info.bin",
            Message.DeviceInfo(
                width = 2560,
                height = 1600,
                density = 320,
                codecs = 0x03,
                name = "Galaxy Tab S9",
                uuid = UUID.fromString("7c9e6679-7425-40de-944b-e07fc1f90ae7"),
            ),
        )
    }

    @Test
    fun displayConfig() {
        check("display_config.bin", Message.DisplayConfig(2560, 1600, 60, Codec.H264))
    }

    @Test
    fun videoConfig() {
        val parameterSets =
            byteArrayOf(0, 0, 0, 1, 0x67, 0x64, 0x00, 0x2A) +
                byteArrayOf(0, 0, 0, 1, 0x68, 0xEE.toByte(), 0x3C, 0xB0.toByte())
        check("video_config.bin", Message.VideoConfig(parameterSets))
    }

    @Test
    fun videoFrameKeyframe() {
        check(
            "video_frame_key.bin",
            Message.VideoFrame(
                timestamp = 1_234_567_890,
                isKeyframe = true,
                data = byteArrayOf(0, 0, 0, 1, 0x65, 0x88.toByte(), 0x84.toByte()),
            ),
        )
    }

    @Test
    fun videoFrameDelta() {
        check(
            "video_frame_delta.bin",
            Message.VideoFrame(
                timestamp = 1_234_584_557,
                isKeyframe = false,
                data = byteArrayOf(0, 0, 0, 1, 0x41, 0x9A.toByte(), 0x22),
            ),
        )
    }

    @Test
    fun inputEvent() {
        check(
            "input_event.bin",
            Message.InputEvent(InputEventKind.MOVE, 0.5f, 0.25f, MouseButton.LEFT, 42),
        )
    }

    @Test
    fun pingPong() {
        check("ping.bin", Message.Ping(0x0102030405060708L))
        check("pong.bin", Message.Pong(0x0102030405060708L))
    }

    @Test
    fun keyframeRequest() {
        check("keyframe_req.bin", Message.KeyframeRequest)
    }

    @Test
    fun stats() {
        check("stats.bin", Message.Stats(120, 3, 2000))
    }

    @Test
    fun bye() {
        check("bye.bin", Message.Bye(ByeReason.TRANSPORT_SWITCH))
    }

    @Test
    fun pairRequest() {
        check("pair_request.bin", Message.PairRequest(428_913))
    }

    @Test
    fun pairResult() {
        check("pair_result.bin", Message.PairResult(true))
    }

    /**
     * The protocol reserves 1 for acceptance: everything else is a refusal, including a code
     * this version does not know yet.
     */
    @Test
    fun pairResultRefuseToutSauf1() {
        val refus = MessageCodec.decodePayload(0x0D, 0, byteArrayOf(0x07))
        assertEquals(Message.PairResult(false), refus)
    }

    @Test
    fun cameraList() {
        check(
            "camera_list.bin",
            Message.CameraList(
                listOf(
                    CameraDescription(0, CameraFacing.BACK, "Back camera"),
                    CameraDescription(1, CameraFacing.FRONT, "Front camera"),
                ),
            ),
        )
    }

    @Test
    fun cameraStart() {
        check("camera_start.bin", Message.CameraStart(1, 1280, 720, 30, Codec.H264))
    }

    @Test
    fun cameraConfig() {
        check(
            "camera_config.bin",
            Message.CameraConfig(
                1280,
                720,
                Codec.H264,
                1,
                byteArrayOf(0, 0, 0, 1, 0x67, 0x42, 0x00, 0, 0, 0, 1, 0x68, 0xCE.toByte()),
            ),
        )
    }

    @Test
    fun cameraFrame() {
        check(
            "camera_frame.bin",
            Message.CameraFrame(987_654_321, true, byteArrayOf(0, 0, 0, 1, 0x65, 0x11, 0x22)),
        )
    }

    @Test
    fun cameraStop() {
        check("camera_stop.bin", Message.CameraStop)
    }

    @Test
    fun videoStop() {
        check("video_stop.bin", Message.VideoStop)
    }

    @Test
    fun typeInconnuIgnorable() {
        check("unknown_type.bin", Message.Unknown(0x7F, 0, "abc".toByteArray()))
    }

    @Test
    fun deuxMessagesDansLeMemePaquet() {
        val decoder = MessageDecoder()
        decoder.append(vector("stream_two_messages.bin"))
        assertEquals(Message.Ping(0x0102030405060708L), decoder.next())
        assertEquals(Message.KeyframeRequest, decoder.next())
        assertNull(decoder.next())
    }

    @Test
    fun messageLivreOctetParOctet() {
        val bytes = vector("hello.bin")
        val decoder = MessageDecoder()

        for (index in 0 until bytes.size - 1) {
            decoder.append(byteArrayOf(bytes[index]))
            assertNull("message yielded before it was complete", decoder.next())
        }

        decoder.append(byteArrayOf(bytes[bytes.size - 1]))
        assertNotNull(decoder.next())
    }

    /** The index based buffer must survive a frame larger than its initial capacity. */
    @Test
    fun grosseFrameEnPlusieursMorceaux() {
        val payload = ByteArray(400_000) { (it % 251).toByte() }
        val encoded = MessageCodec.encode(Message.VideoFrame(42, true, payload))

        val decoder = MessageDecoder(initialCapacity = 4096)
        var offset = 0
        val chunk = 7_000
        while (offset < encoded.size) {
            val count = minOf(chunk, encoded.size - offset)
            decoder.append(encoded.copyOfRange(offset, offset + count), count)
            offset += count
            if (offset < encoded.size) {
                assertNull("message yielded before it was complete", decoder.next())
            }
        }

        val decoded = decoder.next() as Message.VideoFrame
        assertEquals(42L, decoded.timestamp)
        assertTrue(decoded.isKeyframe)
        assertArrayEquals(payload, decoded.data)
        assertNull(decoder.next())
    }

    /** Several messages in a row, to check the buffer compaction. */
    @Test
    fun centMessagesDeSuite() {
        val decoder = MessageDecoder(initialCapacity = 1024)
        repeat(100) { index ->
            decoder.append(MessageCodec.encode(Message.Ping(index.toLong())))
            assertEquals(Message.Ping(index.toLong()), decoder.next())
            assertNull(decoder.next())
        }
    }

    @Test
    fun magicInvalideEstFatal() {
        val decoder = MessageDecoder()
        decoder.append(byteArrayOf(0x00, 0x07, 0x00, 0x00, 0x08, 0x00, 0x00, 0x00))
        try {
            decoder.next()
            fail("an exception was expected")
        } catch (error: ProtocolException) {
            assertTrue(error.message!!.contains("magique"))
        }
    }

    @Test
    fun payloadTropGrand() {
        val decoder = MessageDecoder()
        // length = 16 Mio, au dessus de la borne de 8 Mio.
        decoder.append(byteArrayOf(0x5B, 0x05, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01))
        try {
            decoder.next()
            fail("an exception was expected")
        } catch (error: ProtocolException) {
            assertTrue(error.message!!.contains("borne"))
        }
    }

    @Test
    fun payloadTronque() {
        val decoder = MessageDecoder()
        decoder.append(byteArrayOf(0x5B, 0x07, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 1, 2, 3, 4))
        try {
            decoder.next()
            fail("an exception was expected")
        } catch (error: ProtocolException) {
            assertTrue(error.message!!.contains("truncated"))
        }
    }

    @Test
    fun coordonneesHorsBornesRamenees() {
        val encoded = MessageCodec.encode(
            Message.InputEvent(InputEventKind.DOWN, 1.5f, -0.2f, MouseButton.LEFT, 7)
        )
        val decoder = MessageDecoder()
        decoder.append(encoded)
        assertEquals(
            Message.InputEvent(InputEventKind.DOWN, 1f, 0f, MouseButton.LEFT, 7),
            decoder.next(),
        )
    }

    @Test
    fun nomTropLongTronque() {
        val long = "é".repeat(200) // 400 bytes in UTF-8
        val encoded = MessageCodec.encode(Message.Hello(1, long, UUID.randomUUID()))
        val decoder = MessageDecoder()
        decoder.append(encoded)
        val decoded = decoder.next() as Message.Hello
        assertTrue(decoded.name.toByteArray(Charsets.UTF_8).size <= MessageCodec.MAX_STRING_LENGTH)
        assertTrue(long.startsWith(decoded.name))
    }
}
