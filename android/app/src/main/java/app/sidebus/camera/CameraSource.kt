package app.sidebus.camera

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.graphics.ImageFormat
import android.hardware.camera2.CameraCaptureSession
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraDevice
import android.hardware.camera2.CameraManager
import android.hardware.camera2.CaptureRequest
import android.hardware.camera2.params.OutputConfiguration
import android.hardware.camera2.params.SessionConfiguration
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.os.Handler
import android.os.HandlerThread
import android.util.Log
import android.util.Size
import android.view.Surface
import app.sidebus.protocol.CameraDescription
import app.sidebus.protocol.CameraFacing
import app.sidebus.protocol.Codec
import java.nio.ByteBuffer
import java.util.concurrent.Executor

/**
 * Opens a camera and hands its frames to a hardware encoder, ready to go out as
 * CAMERA_FRAME.
 *
 * The camera writes straight into the encoder's input `Surface`. No pixel ever touches the
 * CPU and no buffer is copied, which is the same arrangement the Mac uses between
 * ScreenCaptureKit and VideoToolbox. Going through `ImageReader` and feeding the encoder by
 * hand would cost a copy per frame for nothing.
 *
 * One camera at a time. Asking for another one stops the first.
 */
class CameraSource(private val context: Context) {

    /** Called for every encoded frame, on the encoder's callback thread. */
    var onFrame: ((data: ByteArray, timestampMicroseconds: Long, isKeyframe: Boolean) -> Unit)? = null

    /** Called once when the encoder produces its parameter sets. */
    var onConfig: ((width: Int, height: Int, codec: Int, parameterSets: ByteArray) -> Unit)? = null

    private val manager = context.getSystemService(CameraManager::class.java)

    private var thread: HandlerThread? = null
    private var handler: Handler? = null
    private var device: CameraDevice? = null
    private var session: CameraCaptureSession? = null
    private var encoder: MediaCodec? = null
    private var inputSurface: Surface? = null

    val isRunning: Boolean get() = device != null

    fun hasPermission(): Boolean =
        context.checkSelfPermission(Manifest.permission.CAMERA) ==
            PackageManager.PERMISSION_GRANTED

    /**
     * Cameras a third party application may actually open.
     *
     * A phone with five sensors usually exposes two, one per facing. The others sit behind a
     * logical camera and are only reachable through its physical identifiers, which most
     * manufacturer builds keep to themselves. Listing what cannot be opened would only
     * offer the user a dead end.
     */
    fun available(): List<CameraDescription> =
        manager.cameraIdList.mapIndexedNotNull { index, id ->
            val characteristics = runCatching { manager.getCameraCharacteristics(id) }.getOrNull()
                ?: return@mapIndexedNotNull null
            val facing = when (characteristics.get(CameraCharacteristics.LENS_FACING)) {
                CameraCharacteristics.LENS_FACING_FRONT -> CameraFacing.FRONT
                CameraCharacteristics.LENS_FACING_EXTERNAL -> CameraFacing.EXTERNAL
                else -> CameraFacing.BACK
            }
            val label = when (facing) {
                CameraFacing.FRONT -> "Front camera"
                CameraFacing.EXTERNAL -> "External camera"
                else -> "Back camera"
            }
            CameraDescription(index, facing, if (manager.cameraIdList.size > 2) "$label $id" else label)
        }

    /**
     * Opens camera [id] and starts encoding. [width] and [height] are a request: the closest
     * size the sensor offers wins, and `onConfig` reports what was actually opened.
     */
    fun start(id: Int, width: Int, height: Int, fps: Int, codec: Int) {
        stop()

        val cameraId = manager.cameraIdList.getOrNull(id) ?: run {
            Log.e(TAG, "no camera at index $id")
            return
        }
        if (!hasPermission()) {
            Log.e(TAG, "camera permission not granted")
            return
        }

        val characteristics = manager.getCameraCharacteristics(cameraId)
        val configurations = characteristics.get(
            CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP
        ) ?: run {
            Log.e(TAG, "camera $cameraId publishes no stream configuration")
            return
        }

        // The encoder consumes a Surface, so the sizes that matter are the ones the sensor
        // offers for private surfaces, not for JPEG.
        val sizes = configurations.getOutputSizes(ImageFormat.PRIVATE)
            ?: configurations.getOutputSizes(MediaCodec::class.java)
        val size = closest(sizes, width, height) ?: run {
            Log.e(TAG, "camera $cameraId offers no usable size")
            return
        }
        Log.i(TAG, "camera $cameraId opening at ${size.width}x${size.height}, asked ${width}x$height")

        val thread = HandlerThread("sidebus-camera").apply { start() }
        this.thread = thread
        val handler = Handler(thread.looper)
        this.handler = handler
        val executor = Executor { handler.post(it) }

        val mime = if (codec == Codec.HEVC) {
            MediaFormat.MIMETYPE_VIDEO_HEVC
        } else {
            MediaFormat.MIMETYPE_VIDEO_AVC
        }

        val encoder = MediaCodec.createEncoderByType(mime)
        this.encoder = encoder

        val format = MediaFormat.createVideoFormat(mime, size.width, size.height).apply {
            setInteger(
                MediaFormat.KEY_COLOR_FORMAT,
                MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface,
            )
            setInteger(MediaFormat.KEY_BIT_RATE, bitrateFor(size, fps))
            setInteger(MediaFormat.KEY_FRAME_RATE, fps)
            // One keyframe a second. A webcam viewer joins at any moment, and unlike the
            // screen stream there is no keyframe request to lean on.
            setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 1)
            setInteger(MediaFormat.KEY_LATENCY, 1)
            setInteger(MediaFormat.KEY_PRIORITY, 0)
        }

        encoder.setCallback(encoderCallback, handler)
        encoder.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
        val surface = encoder.createInputSurface()
        inputSurface = surface
        encoder.start()

        this.openedSize = size
        this.openedCodec = codec

        openCamera(cameraId, surface, fps, executor)
    }

    fun stop() {
        session?.let { runCatching { it.close() } }
        session = null
        device?.let { runCatching { it.close() } }
        device = null
        encoder?.let {
            runCatching { it.stop() }
            runCatching { it.release() }
        }
        encoder = null
        inputSurface?.release()
        inputSurface = null
        thread?.quitSafely()
        thread = null
        handler = null
        sentConfig = false
    }

    // MARK: camera

    private var openedSize: Size? = null
    private var openedCodec: Int = Codec.H264
    private var sentConfig = false

    @Suppress("MissingPermission")
    private fun openCamera(cameraId: String, surface: Surface, fps: Int, executor: Executor) {
        manager.openCamera(cameraId, executor, object : CameraDevice.StateCallback() {
            override fun onOpened(camera: CameraDevice) {
                device = camera
                configureSession(camera, surface, fps, executor)
            }

            override fun onDisconnected(camera: CameraDevice) {
                Log.w(TAG, "camera disconnected")
                stop()
            }

            override fun onError(camera: CameraDevice, error: Int) {
                Log.e(TAG, "camera error $error")
                stop()
            }
        })
    }

    private fun configureSession(
        camera: CameraDevice,
        surface: Surface,
        fps: Int,
        executor: Executor,
    ) {
        val configuration = SessionConfiguration(
            SessionConfiguration.SESSION_REGULAR,
            listOf(OutputConfiguration(surface)),
            executor,
            object : CameraCaptureSession.StateCallback() {
                override fun onConfigured(configured: CameraCaptureSession) {
                    session = configured
                    val request = camera.createCaptureRequest(CameraDevice.TEMPLATE_RECORD).apply {
                        addTarget(surface)
                        set(
                            CaptureRequest.CONTROL_AE_TARGET_FPS_RANGE,
                            android.util.Range(fps, fps),
                        )
                    }.build()
                    runCatching { configured.setRepeatingRequest(request, null, handler) }
                        .onFailure { Log.e(TAG, "repeating request refused", it) }
                }

                override fun onConfigureFailed(configured: CameraCaptureSession) {
                    Log.e(TAG, "capture session configuration failed")
                    stop()
                }
            },
        )
        runCatching { camera.createCaptureSession(configuration) }
            .onFailure { Log.e(TAG, "cannot create the capture session", it) }
    }

    // MARK: encoder

    private val encoderCallback = object : MediaCodec.Callback() {
        // Nothing to do: frames arrive through the input Surface, not through buffers.
        override fun onInputBufferAvailable(codec: MediaCodec, index: Int) = Unit

        override fun onOutputBufferAvailable(
            codec: MediaCodec,
            index: Int,
            info: MediaCodec.BufferInfo,
        ) {
            val buffer = codec.getOutputBuffer(index)
            if (buffer != null && info.size > 0) {
                deliver(buffer, info)
            }
            runCatching { codec.releaseOutputBuffer(index, false) }
        }

        override fun onOutputFormatChanged(codec: MediaCodec, format: MediaFormat) {
            // csd-0 and csd-1 carry the parameter sets. Concatenated they are already the
            // Annex B blob CAMERA_CONFIG expects.
            val size = openedSize ?: return
            val sets = listOfNotNull(format.getByteBuffer("csd-0"), format.getByteBuffer("csd-1"))
                .fold(ByteArray(0)) { acc, buffer ->
                    val bytes = ByteArray(buffer.remaining())
                    buffer.duplicate().get(bytes)
                    acc + bytes
                }
            if (sets.isEmpty()) return
            sentConfig = true
            onConfig?.invoke(size.width, size.height, openedCodec, sets)
        }

        override fun onError(codec: MediaCodec, error: MediaCodec.CodecException) {
            Log.e(TAG, "camera encoder error", error)
        }
    }

    private fun deliver(buffer: ByteBuffer, info: MediaCodec.BufferInfo) {
        val isConfig = info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG != 0
        val bytes = ByteArray(info.size)
        buffer.position(info.offset)
        buffer.get(bytes)

        if (isConfig) {
            // Some encoders deliver the parameter sets as a frame rather than through
            // onOutputFormatChanged. Either path is fine, the first one to arrive wins.
            if (!sentConfig) {
                val size = openedSize ?: return
                sentConfig = true
                onConfig?.invoke(size.width, size.height, openedCodec, bytes)
            }
            return
        }

        val isKeyframe = info.flags and MediaCodec.BUFFER_FLAG_KEY_FRAME != 0
        onFrame?.invoke(bytes, info.presentationTimeUs, isKeyframe)
    }

    /// Closest offered size to the request, by area, never larger than asked.
    private fun closest(sizes: Array<Size>?, width: Int, height: Int): Size? {
        if (sizes.isNullOrEmpty()) return null
        val wanted = width.toLong() * height.toLong()
        return sizes.minByOrNull { candidate ->
            val area = candidate.width.toLong() * candidate.height.toLong()
            // A slightly smaller size beats a much larger one: encoding pixels nobody asked
            // for costs bandwidth and heat.
            if (area <= wanted) wanted - area else (area - wanted) * 3
        }
    }

    private fun bitrateFor(size: Size, fps: Int): Int {
        // About 0.1 bit per pixel per frame. Generous enough for a face on a plain
        // background, which is what a webcam films.
        val estimate = (size.width.toLong() * size.height * fps / 10).toInt()
        return estimate.coerceIn(1_000_000, 12_000_000)
    }

    private companion object {
        const val TAG = "Sidebus"
    }
}
