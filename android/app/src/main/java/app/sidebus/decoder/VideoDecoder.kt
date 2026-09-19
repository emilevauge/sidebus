package app.sidebus.decoder

import android.media.MediaCodec
import android.media.MediaFormat
import android.os.Handler
import android.os.HandlerThread
import android.util.Log
import android.view.Surface
import app.sidebus.protocol.Codec
import java.nio.ByteBuffer
import java.util.concurrent.ConcurrentLinkedQueue
import java.util.concurrent.atomic.AtomicLong

/**
 * Hardware decoder rendering straight into a `Surface`.
 *
 * Two rules carry all of this class's latency:
 *
 * - no queue at render time. `releaseOutputBuffer(index, true)` is called as soon as the
 *   frame leaves the decoder, with no wait on a timestamp.
 * - when late, drop. If no input buffer is free the frame is dropped rather than queued:
 *   buffering only moves the lag around.
 */
class VideoDecoder(
    private val surface: Surface,
    private val onFrameRendered: (latencyMillis: Long) -> Unit,
    private val onFrameDropped: () -> Unit,
) {
    private var codec: MediaCodec? = null
    private val thread = HandlerThread("sidebus-decoder").apply { start() }
    private val handler = Handler(thread.looper)

    /** Indices of the free input buffers, filled by the decoder's callback. */
    private val freeInputBuffers = ConcurrentLinkedQueue<Int>()

    /** Receive timestamps, to measure the time spent inside the decoder. */
    private val receivedAt = AtomicLong(0)

    fun configure(width: Int, height: Int, parameterSets: ByteArray, codec: Int) {
        release()

        // In HEVC, `csd-0` carries VPS, SPS and PPS concatenated, exactly what the Mac sends
        // in VIDEO_CONFIG.
        val mime = if (codec == Codec.HEVC) {
            MediaFormat.MIMETYPE_VIDEO_HEVC
        } else {
            MediaFormat.MIMETYPE_VIDEO_AVC
        }

        val format = MediaFormat.createVideoFormat(mime, width, height).apply {
            setByteBuffer("csd-0", ByteBuffer.wrap(parameterSets))
            // Asks the decoder not to pile up frames before yielding the first one.
            setInteger(MediaFormat.KEY_LOW_LATENCY, 1)
            // 0 = realtime.
            setInteger(MediaFormat.KEY_PRIORITY, 0)
        }

        val decoder = MediaCodec.createDecoderByType(mime)
        decoder.setCallback(
            object : MediaCodec.Callback() {
                override fun onInputBufferAvailable(codec: MediaCodec, index: Int) {
                    freeInputBuffers.add(index)
                }

                override fun onOutputBufferAvailable(
                    codec: MediaCodec,
                    index: Int,
                    info: MediaCodec.BufferInfo,
                ) {
                    // Immediate rendering, no queue.
                    codec.releaseOutputBuffer(index, true)
                    val elapsed = System.nanoTime() - receivedAt.get()
                    onFrameRendered(elapsed / 1_000_000)
                }

                override fun onOutputFormatChanged(codec: MediaCodec, format: MediaFormat) {
                    Log.i(TAG, "format de sortie : $format")
                }

                override fun onError(codec: MediaCodec, error: MediaCodec.CodecException) {
                    Log.e(TAG, "decoder error", error)
                }
            },
            handler,
        )

        decoder.configure(format, surface, null, 0)
        decoder.start()
        this.codec = decoder
        Log.i(TAG, "decoder $mime started at ${width}x$height")
    }

    /**
     * Pushes a frame to the decoder. Returns false when it was dropped.
     *
     * An intermediate frame is dropped without remorse. A keyframe is not: it is the only
     * point the decoder can restart from after a burst of drops, and the next one can be five
     * seconds away. So it gets a short window to find a free buffer.
     */
    fun submit(data: ByteArray, timestampMicroseconds: Long, isKeyframe: Boolean): Boolean {
        val codec = this.codec ?: return false

        var index = freeInputBuffers.poll()
        if (index == null) {
            // A short wait avoids most needless drops without building a queue: a few
            // milliseconds cost less than a broken picture.
            val wait = if (isKeyframe) KEYFRAME_WAIT_NANOS else FRAME_WAIT_NANOS
            val deadline = System.nanoTime() + wait
            while (index == null && System.nanoTime() < deadline) {
                Thread.sleep(1)
                index = freeInputBuffers.poll()
            }
        }
        if (index == null) {
            onFrameDropped()
            return false
        }

        val buffer = try {
            codec.getInputBuffer(index)
        } catch (error: IllegalStateException) {
            onFrameDropped()
            return false
        } ?: return false

        buffer.clear()
        buffer.put(data)
        receivedAt.set(System.nanoTime())
        codec.queueInputBuffer(index, 0, data.size, timestampMicroseconds, 0)
        return true
    }

    fun release() {
        freeInputBuffers.clear()
        codec?.let {
            runCatching { it.stop() }
            runCatching { it.release() }
        }
        codec = null
    }

    fun shutdown() {
        release()
        thread.quitSafely()
    }

    companion object {
        private const val TAG = "Sidebus"

        /** Longest wait for an input buffer, for a keyframe. */
        private const val KEYFRAME_WAIT_NANOS = 30_000_000L

        /** The same for an intermediate frame, far shorter. */
        private const val FRAME_WAIT_NANOS = 5_000_000L
    }
}
