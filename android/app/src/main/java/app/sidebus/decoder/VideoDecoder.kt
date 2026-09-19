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
 * Décodeur H.264 rendu directement dans une `Surface`.
 *
 * Deux règles tiennent toute la latence de cette classe :
 *
 * - aucune file d'attente au rendu. `releaseOutputBuffer(index, true)` est appelé dès que
 *   la frame sort du décodeur, sans attendre d'horodatage.
 * - en retard, on jette. Si aucun buffer d'entrée n'est libre, la frame est droppée plutôt
 *   que mise en attente : bufferiser ne fait que déplacer le retard.
 */
class VideoDecoder(
    private val surface: Surface,
    private val onFrameRendered: (latencyMillis: Long) -> Unit,
    private val onFrameDropped: () -> Unit,
) {
    private var codec: MediaCodec? = null
    private val thread = HandlerThread("sidebus-decoder").apply { start() }
    private val handler = Handler(thread.looper)

    /** Index des buffers d'entrée libres, remplis par le callback du décodeur. */
    private val freeInputBuffers = ConcurrentLinkedQueue<Int>()

    /** Horodatage de réception, pour mesurer le temps passé dans le décodeur. */
    private val receivedAt = AtomicLong(0)

    fun configure(width: Int, height: Int, parameterSets: ByteArray, codec: Int) {
        release()

        // En HEVC, `csd-0` porte VPS, SPS et PPS concaténés, exactement ce que le Mac
        // envoie dans VIDEO_CONFIG.
        val mime = if (codec == Codec.HEVC) {
            MediaFormat.MIMETYPE_VIDEO_HEVC
        } else {
            MediaFormat.MIMETYPE_VIDEO_AVC
        }

        val format = MediaFormat.createVideoFormat(mime, width, height).apply {
            setByteBuffer("csd-0", ByteBuffer.wrap(parameterSets))
            // Demande au décodeur de ne pas accumuler de frames avant de sortir la première.
            setInteger(MediaFormat.KEY_LOW_LATENCY, 1)
            // 0 = temps réel.
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
                    // Rendu immédiat, sans file d'attente.
                    codec.releaseOutputBuffer(index, true)
                    val elapsed = System.nanoTime() - receivedAt.get()
                    onFrameRendered(elapsed / 1_000_000)
                }

                override fun onOutputFormatChanged(codec: MediaCodec, format: MediaFormat) {
                    Log.i(TAG, "format de sortie : $format")
                }

                override fun onError(codec: MediaCodec, error: MediaCodec.CodecException) {
                    Log.e(TAG, "erreur du décodeur", error)
                }
            },
            handler,
        )

        decoder.configure(format, surface, null, 0)
        decoder.start()
        this.codec = decoder
        Log.i(TAG, "décodeur $mime démarré en ${width}x$height")
    }

    /**
     * Pousse une frame au décodeur. Renvoie false si elle a été droppée.
     *
     * Une frame intermédiaire se jette sans remords. Une keyframe, non : c'est le seul
     * point d'où le décodeur peut repartir après une salve de droppes, et la suivante
     * peut être à cinq secondes. On lui laisse donc une courte fenêtre pour trouver un
     * buffer libre.
     */
    fun submit(data: ByteArray, timestampMicroseconds: Long, isKeyframe: Boolean): Boolean {
        val codec = this.codec ?: return false

        var index = freeInputBuffers.poll()
        if (index == null) {
            // Une courte attente évite la plupart des droppes inutiles, sans construire
            // de file : quelques millisecondes coûtent moins cher qu'une image cassée.
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

        /** Attente maximale d'un buffer d'entrée pour une keyframe. */
        private const val KEYFRAME_WAIT_NANOS = 30_000_000L

        /** Idem pour une frame intermédiaire, bien plus courte. */
        private const val FRAME_WAIT_NANOS = 5_000_000L
    }
}
