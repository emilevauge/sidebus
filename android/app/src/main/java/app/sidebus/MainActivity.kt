package app.sidebus

import android.app.Activity
import android.app.AlertDialog
import android.graphics.Color
import android.os.Bundle
import android.provider.Settings
import android.util.Log
import android.view.Gravity
import android.view.SurfaceHolder
import android.view.View
import android.view.SurfaceView
import android.view.WindowInsets
import android.view.WindowInsetsController
import android.view.WindowManager
import android.widget.FrameLayout
import android.widget.Toast
import app.sidebus.camera.CameraSource
import app.sidebus.decoder.VideoDecoder
import app.sidebus.input.TouchSender
import app.sidebus.pairing.DeviceIdentity
import app.sidebus.protocol.Message
import app.sidebus.transport.Connection
import app.sidebus.transport.ServiceAdvertiser
import app.sidebus.transport.TransportServer
import app.sidebus.ui.DebugOverlay
import app.sidebus.ui.WaitingView
import java.net.Inet4Address
import java.net.NetworkInterface
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * The rendering screen. A full screen `SurfaceView`, never a `TextureView`: the latter
 * always adds a frame of latency.
 */
class MainActivity : Activity(), SurfaceHolder.Callback {

    private lateinit var root: FrameLayout
    private lateinit var surfaceView: SurfaceView
    private lateinit var curtain: WaitingView
    private lateinit var overlay: DebugOverlay

    private val scope = CoroutineScope(Dispatchers.Main.immediate + Job())
    private var connection: Connection? = null
    private var decoder: VideoDecoder? = null
    @Volatile private var surfaceReady = false
    @Volatile private var pendingConfig: Message.DisplayConfig? = null
    @Volatile private var parameterSets: ByteArray? = null
    /** Until a keyframe has gone through, the decoder can produce nothing. */
    @Volatile private var awaitingKeyframe = true
    private val decoderLock = Any()
    private var statsJob: Job? = null
    private var lastKeyframeRequest = 0L
    /** Name of the Mac announced in HELLO, shown in the pairing prompt. */
    @Volatile private var peerName = "ce Mac"
    private var pairingDialog: AlertDialog? = null
    /** CAMERA_START held back while the permission dialog is up. */
    private var pendingCameraStart: Message.CameraStart? = null
    private lateinit var touch: TouchSender
    private lateinit var advertiser: ServiceAdvertiser
    private lateinit var camera: CameraSource

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        root = FrameLayout(this).apply { setBackgroundColor(Color.BLACK) }

        surfaceView = SurfaceView(this)
        surfaceView.holder.addCallback(this)
        touch = TouchSender(scope)
        surfaceView.setOnTouchListener { view, event -> touch.onTouch(view, event) }
        root.addView(
            surfaceView,
            FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT,
                FrameLayout.LayoutParams.MATCH_PARENT,
                Gravity.CENTER,
            ),
        )

        // The waiting screen, which doubles as the curtain over the video. See `WaitingView`
        // for the two surface traps it avoids.
        curtain = WaitingView(this).apply {
            setOnLongClickListener {
                resetPairing()
                true
            }
        }
        root.addView(
            curtain,
            FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT,
                FrameLayout.LayoutParams.MATCH_PARENT,
            ),
        )

        overlay = DebugOverlay(this)
        // Hidden by default: the numbers are there to diagnose, not to sit across the shared
        // screen. The view keeps counting even while invisible, and it is what feeds the
        // STATS messages.
        overlay.visibility = if (overlayRequested()) View.VISIBLE else View.GONE
        root.addView(
            overlay,
            FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.WRAP_CONTENT,
                FrameLayout.LayoutParams.WRAP_CONTENT,
                Gravity.TOP or Gravity.START,
            ),
        )

        setContentView(root)

        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        window.setSustainedPerformanceMode(true)
        window.setDecorFitsSystemWindows(false)
        window.insetsController?.let { controller ->
            controller.hide(WindowInsets.Type.systemBars())
            controller.systemBarsBehavior =
                WindowInsetsController.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
        }

        advertiser = ServiceAdvertiser(this)
        camera = CameraSource(this)

        show("Starting")
        startServer()
    }

    /**
     * Advertising follows visibility, not focus.
     *
     * A system dialog laid over the activity, the camera permission prompt above all, pauses
     * it without hiding it. Tying the advertisement to `onResume` withdrew it the moment the
     * question appeared, the Mac saw the tablet vanish from discovery, and it dropped the
     * device while the socket was still perfectly alive.
     */
    override fun onStart() {
        super.onStart()
        advertiser.start(TransportServer.DEFAULT_PORT, DeviceDescriptor.deviceInfo(this))
    }

    override fun onResume() {
        super.onResume()
        // Read again on every return to the foreground: the setting can be changed over adb
        // without restarting the app.
        overlay.visibility = if (overlayRequested()) View.VISIBLE else View.GONE
    }

    /**
     * Counters display, on demand:
     * `adb shell settings put global sidebus_overlay 1`, and 0 to hide them again.
     *
     * A global setting rather than a system property: it reads through a public API, with no
     * reflection and no call to getprop, and it can be changed live.
     */
    private fun overlayRequested(): Boolean =
        Settings.Global.getString(contentResolver, "sidebus_overlay") == "1"

    override fun onStop() {
        advertiser.stop()
        super.onStop()
    }

    override fun onDestroy() {
        camera.stop()
        scope.coroutineContext[Job]?.cancel()
        decoder?.shutdown()
        connection?.close()
        super.onDestroy()
    }

    // MARK: surface

    override fun surfaceCreated(holder: SurfaceHolder) {
        Log.i(TAG, "surface created")
        surfaceReady = true
        startDecoderIfReady()
    }

    override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) = Unit

    override fun surfaceDestroyed(holder: SurfaceHolder) {
        surfaceReady = false
        synchronized(decoderLock) {
            decoder?.release()
            decoder = null
        }
    }

    // MARK: transport

    private fun startServer() {
        val info = DeviceDescriptor.deviceInfo(this)
        val pairingCode = DeviceIdentity.pairingCode()
        val sslFactory = DeviceIdentity.sslContext().serverSocketFactory as javax.net.ssl.SSLServerSocketFactory
        scope.launch {
            TransportServer(serverSocketFactory = sslFactory).run { event ->
                when (event) {
                    is TransportServer.Event.Listening ->
                        show("Waiting for a Mac", "${localAddress()}:${event.port}", pairingCode)

                    is TransportServer.Event.Connected -> {
                        show("Connected", "${event.remote}")
                        startStatsReporting()
                    }

                    is TransportServer.Event.Received -> handle(event.message, event.connection, info)

                    is TransportServer.Event.Disconnected -> {
                        connection = null
                        touch.attach(null)
                        statsJob?.cancel()
                        statsJob = null
                        stopRendering()
                        camera.stop()
                        runOnUiThread {
                            pairingDialog?.dismiss()
                            pairingDialog = null
                        }
                        show(
                            "Waiting for a Mac",
                            "${localAddress()}  ·  ${event.reason}",
                            pairingCode,
                        )
                    }

                    is TransportServer.Event.Failed -> show("Error", event.error.message)
                }
            }
        }
    }

    private suspend fun handle(
        message: Message,
        connection: Connection,
        info: Message.DeviceInfo,
    ) {
        this.connection = connection
        touch.attach(connection)
        when (message) {
            is Message.Hello -> {
                Log.i(TAG, "HELLO from ${message.name}, protocol ${message.version}")
                peerName = message.name
                show("Connected to ${message.name}", "waiting for the stream")
                withContext(Dispatchers.IO) {
                    connection.send(info)
                    // Unsolicited, right after DEVICE_INFO, as the protocol says. A Mac that
                    // does not care about cameras ignores it.
                    connection.send(Message.CameraList(camera.available()))
                }
            }

            is Message.DisplayConfig -> {
                Log.i(TAG, "DISPLAY_CONFIG ${message.width}x${message.height} @${message.fps}")
                pendingConfig = message
                runOnUiThread { fitSurface(message.width, message.height) }
                startDecoderIfReady()
            }

            is Message.VideoConfig -> {
                Log.i(TAG, "VIDEO_CONFIG ${message.parameterSets.size} octets")
                parameterSets = message.parameterSets
                // Created synchronously: the next frame is the keyframe, and it is the only
                // one for a long while. A decoder created later would miss it and stay
                // stuck on unusable intermediate frames.
                startDecoderIfReady()
            }

            is Message.VideoFrame -> {
                val decoder = this.decoder
                if (decoder == null) {
                    overlay.onFrameDropped()
                    return
                }
                if (awaitingKeyframe && !message.isKeyframe) {
                    overlay.onFrameDropped()
                    requestKeyframe(connection)
                    return
                }
                if (decoder.submit(message.data, message.timestamp, message.isKeyframe)) {
                    awaitingKeyframe = false
                    overlay.onFrameReceived(message.data.size)
                }
            }

            is Message.Ping -> withContext(Dispatchers.IO) {
                connection.send(Message.Pong(message.timestamp))
            }

            is Message.PairRequest -> askPairing(message.code, connection)

            is Message.CameraStart -> startCamera(message, connection)

            is Message.CameraStop -> {
                Log.i(TAG, "CAMERA_STOP")
                camera.stop()
            }

            is Message.VideoStop -> {
                Log.i(TAG, "VIDEO_STOP")
                stopRendering()
                show("Connected to $peerName", "screen sharing stopped")
            }

            is Message.Bye -> Log.i(TAG, "BYE, reason ${message.reason}")

            is Message.Unknown ->
                Log.i(TAG, "unknown message type 0x%02X ignored".format(message.type))

            else -> Log.d(TAG, "received ${message::class.simpleName}")
        }
    }

    /**
     * Opens the camera the Mac asked for and starts pushing CAMERA_FRAME.
     *
     * The permission is requested here rather than at launch: a tablet used only as a second
     * display never needs the camera, and asking for it up front would look like overreach.
     * The request is asynchronous, so the first CAMERA_START after a refusal simply does
     * nothing and the Mac sees no frames.
     */
    private fun startCamera(request: Message.CameraStart, connection: Connection) {
        Log.i(
            TAG,
            "CAMERA_START id=${request.id} ${request.width}x${request.height} @${request.fps}",
        )

        if (!camera.hasPermission()) {
            Log.i(TAG, "camera permission missing, asking")
            runOnUiThread {
                requestPermissions(arrayOf(android.Manifest.permission.CAMERA), CAMERA_PERMISSION)
            }
            pendingCameraStart = request
            return
        }

        camera.onConfig = { width, height, codec, rotation, parameterSets ->
            scope.launch(Dispatchers.IO) {
                runCatching {
                    connection.send(
                        Message.CameraConfig(width, height, codec, rotation, parameterSets),
                    )
                }
            }
        }
        camera.onFrame = { data, timestamp, isKeyframe ->
            scope.launch(Dispatchers.IO) {
                runCatching {
                    connection.send(Message.CameraFrame(timestamp, isKeyframe, data))
                }
            }
        }
        camera.start(request.id, request.width, request.height, request.fps, request.codec)
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != CAMERA_PERMISSION) return

        val granted = grantResults.firstOrNull() == android.content.pm.PackageManager.PERMISSION_GRANTED
        val request = pendingCameraStart
        pendingCameraStart = null
        val connection = this.connection

        if (!granted) {
            // A second refusal is permanent: Android answers on the spot from then on and
            // never shows the dialog again. Say so, otherwise the Mac just waits on a
            // camera that will never open.
            Log.i(TAG, "camera permission refused")
            Toast.makeText(
                this,
                "Camera refused. Allow it in Android settings to use it as a webcam.",
                Toast.LENGTH_LONG,
            ).show()
            return
        }
        if (request == null || connection == null) {
            Log.i(TAG, "camera permission granted but the request is gone")
            return
        }
        scope.launch { startCamera(request, connection) }
    }

    /**
     * Pairing confirmation request received from the Mac.
     *
     * The dialog does **not** block the read loop: the Mac expects a PONG every second and
     * cuts after five seconds of silence, so suspending reading while the user answers would
     * kill the connection before the answer came. Show it, hand control back, and the answer
     * goes out when it arrives.
     */
    private fun askPairing(code: Int, connection: Connection) {
        val received = "%06d".format(code)
        val local = DeviceIdentity.pairingCode()
        Log.i(TAG, "PAIR_REQUEST, code received $received, local code $local")

        runOnUiThread {
            pairingDialog?.dismiss()

            // Both codes derive from the same certificate. If they differ, the Mac is not
            // talking to this tablet: say so instead of letting the user confirm blind.
            val message = if (received == local) {
                "Code: $local\n\nCheck that the Mac shows the same code."
            } else {
                "Careful: the Mac shows $received, this tablet $local.\n\n" +
                    "Both codes should be identical. Refuse, unless you know exactly " +
                    "why they differ."
            }

            pairingDialog = AlertDialog.Builder(this, R.style.Theme_Sidebus_Dialog)
                .setTitle("Pair with $peerName?")
                .setMessage(message)
                .setCancelable(false)
                .setPositiveButton("Pair") { _, _ -> answerPairing(true, connection) }
                .setNegativeButton("Refuse") { _, _ -> answerPairing(false, connection) }
                .show()
        }
    }

    private fun answerPairing(accepted: Boolean, connection: Connection) {
        pairingDialog = null
        Log.i(TAG, "pairing ${if (accepted) "accepted" else "refused"}")
        scope.launch(Dispatchers.IO) {
            runCatching { connection.send(Message.PairResult(accepted)) }
        }
    }

    /**
     * Reports at a fixed interval what the tablet actually displayed. That is what the Mac
     * uses to adjust its bitrate, and as a last resort its frame rate.
     */
    private fun startStatsReporting() {
        if (statsJob != null) return
        statsJob = scope.launch(Dispatchers.IO) {
            while (true) {
                delay(STATS_INTERVAL_MS)
                val connection = this@MainActivity.connection ?: continue
                val (received, dropped) = overlay.takeStats()
                if (received == 0 && dropped == 0) continue
                runCatching {
                    connection.send(Message.Stats(received, dropped, STATS_INTERVAL_MS.toInt()))
                }
            }
        }
    }

    /** At most one request per second: no point sending one per lost frame. */
    private fun requestKeyframe(connection: Connection) {
        val now = System.currentTimeMillis()
        if (now - lastKeyframeRequest < 1_000) return
        lastKeyframeRequest = now
        scope.launch(Dispatchers.IO) {
            runCatching { connection.send(Message.KeyframeRequest) }
        }
    }

    private fun startDecoderIfReady() {
        synchronized(decoderLock) {
            if (decoder != null) return
            val config = pendingConfig
            val csd = parameterSets
            if (config == null || csd == null || !surfaceReady) {
                Log.i(
                    TAG,
                    "decoder not ready: config=${config != null} csd=${csd != null} surface=$surfaceReady",
                )
                return
            }

            awaitingKeyframe = true
            val created = VideoDecoder(
                surface = surfaceView.holder.surface,
                onFrameRendered = { latency -> overlay.onFrameRendered(latency) },
                onFrameDropped = { overlay.onFrameDropped() },
            )
            // A decoder that refuses to configure must not take the connection down with it:
            // stay connected, screen black, and try again on the next VIDEO_CONFIG.
            try {
                created.configure(config.width, config.height, csd, config.codec)
            } catch (error: Exception) {
                Log.e(TAG, "cannot configure the decoder", error)
                created.shutdown()
                parameterSets = null
                return
            }
            decoder = created
        }

        runOnUiThread {
            curtain.visibility = View.GONE
            overlay.transport = "USB"
        }
    }

    /**
     * Drops the decoder and shows the waiting screen again, the link untouched.
     *
     * VIDEO_STOP, or a disconnection. Silence cannot stand in for it: nothing is encoded
     * while the shared screen does not change, so an idle stream looks exactly like a stream
     * that has ended.
     */
    private fun stopRendering() {
        synchronized(decoderLock) {
            decoder?.release()
            decoder = null
        }
        pendingConfig = null
        parameterSets = null
        awaitingKeyframe = true
        // Never go INVISIBLE: that destroys the surface, which is then never recreated, and
        // the decoder cannot restart on the next connection.
        runOnUiThread { curtain.visibility = View.VISIBLE }
    }

    /**
     * Forgets the tablet's identity and restarts the screen. The Mac will see it as an
     * unknown device and ask for a pairing code again.
     */
    private fun resetPairing() {
        Log.i(TAG, "unpairing requested")
        connection?.close()
        DeviceIdentity.reset(this)
        Toast.makeText(this, "Pairing reset", Toast.LENGTH_SHORT).show()
        recreate()
    }

    /** Keeps the stream's aspect ratio, black bars and all. */
    private fun fitSurface(width: Int, height: Int) {
        root.post {
            val available = root.width to root.height
            if (available.first == 0 || available.second == 0) return@post

            val scale = minOf(
                available.first.toFloat() / width,
                available.second.toFloat() / height,
            )
            surfaceView.layoutParams = FrameLayout.LayoutParams(
                (width * scale).toInt(),
                (height * scale).toInt(),
                Gravity.CENTER,
            )
        }
    }

    private fun show(etat: String, detail: String? = null, code: String? = null) {
        runOnUiThread { curtain.show(etat, detail, code) }
    }

    /** IPv4 address, shown for the manual fallback. */
    private fun localAddress(): String =
        NetworkInterface.getNetworkInterfaces().toList()
            .filter { it.isUp && !it.isLoopback }
            .flatMap { it.inetAddresses.toList() }
            .filterIsInstance<Inet4Address>()
            .firstOrNull()
            ?.hostAddress
            ?: "127.0.0.1"

    companion object {
        private const val TAG = "Sidebus"
        private const val STATS_INTERVAL_MS = 2_000L
        private const val CAMERA_PERMISSION = 1
    }
}
