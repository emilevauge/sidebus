package app.sidebus

import android.app.Activity
import android.graphics.Color
import android.os.Bundle
import android.util.Log
import android.view.Gravity
import android.view.SurfaceHolder
import android.view.View
import android.view.SurfaceView
import android.view.WindowInsets
import android.view.WindowInsetsController
import android.view.WindowManager
import android.widget.FrameLayout
import android.widget.TextView
import app.sidebus.decoder.VideoDecoder
import app.sidebus.input.TouchSender
import app.sidebus.pairing.DeviceIdentity
import app.sidebus.protocol.Message
import app.sidebus.transport.Connection
import app.sidebus.transport.ServiceAdvertiser
import app.sidebus.transport.TransportServer
import app.sidebus.ui.DebugOverlay
import java.net.Inet4Address
import java.net.NetworkInterface
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * Écran de rendu. Une `SurfaceView` plein écran, jamais une `TextureView` : celle ci
 * ajoute systématiquement une frame de latence.
 */
class MainActivity : Activity(), SurfaceHolder.Callback {

    private lateinit var root: FrameLayout
    private lateinit var surfaceView: SurfaceView
    private lateinit var curtain: View
    private lateinit var status: TextView
    private lateinit var overlay: DebugOverlay

    private val scope = CoroutineScope(Dispatchers.Main.immediate + Job())
    private var connection: Connection? = null
    private var decoder: VideoDecoder? = null
    @Volatile private var surfaceReady = false
    @Volatile private var pendingConfig: Message.DisplayConfig? = null
    @Volatile private var parameterSets: ByteArray? = null
    /** Tant qu'aucune keyframe n'est passée, le décodeur ne peut rien produire. */
    @Volatile private var awaitingKeyframe = true
    private val decoderLock = Any()
    private var statsJob: Job? = null
    private var lastKeyframeRequest = 0L
    private lateinit var touch: TouchSender
    private lateinit var advertiser: ServiceAdvertiser

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

        // Rideau noir au dessus de la vidéo. Surtout pas `lockCanvas` sur la surface pour
        // l'effacer : cela la connecte au producteur CPU et MediaCodec ne peut plus s'y
        // attacher ensuite, la configuration du décodeur échoue.
        curtain = View(this).apply { setBackgroundColor(Color.BLACK) }
        root.addView(
            curtain,
            FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT,
                FrameLayout.LayoutParams.MATCH_PARENT,
            ),
        )

        status = TextView(this).apply {
            setTextColor(Color.WHITE)
            textSize = 16f
            gravity = Gravity.CENTER
        }
        root.addView(
            status,
            FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT,
                FrameLayout.LayoutParams.WRAP_CONTENT,
                Gravity.CENTER,
            ),
        )

        overlay = DebugOverlay(this)
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

        show("démarrage")
        startServer()
    }

    override fun onResume() {
        super.onResume()
        advertiser.start(TransportServer.DEFAULT_PORT, DeviceDescriptor.deviceInfo(this))
    }

    override fun onPause() {
        advertiser.stop()
        super.onPause()
    }

    override fun onDestroy() {
        scope.coroutineContext[Job]?.cancel()
        decoder?.shutdown()
        connection?.close()
        super.onDestroy()
    }

    // MARK: surface

    override fun surfaceCreated(holder: SurfaceHolder) {
        Log.i(TAG, "surface créée")
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
                        show(
                            "en écoute sur ${localAddress()}:${event.port}" +
                                "\n\ncode d'appairage : $pairingCode"
                        )

                    is TransportServer.Event.Connected -> {
                        show("connecté à ${event.remote}")
                        startStatsReporting()
                    }

                    is TransportServer.Event.Received -> handle(event.message, event.connection, info)

                    is TransportServer.Event.Disconnected -> {
                        connection = null
                        touch.attach(null)
                        statsJob?.cancel()
                        statsJob = null
                        synchronized(decoderLock) {
                            decoder?.release()
                            decoder = null
                        }
                        parameterSets = null
                        // Surtout pas de passage en INVISIBLE : cela détruit la surface,
                        // qui n'est alors jamais recréée, et le décodeur ne peut plus
                        // redémarrer à la connexion suivante.
                        runOnUiThread { curtain.visibility = View.VISIBLE }
                        show(
                            "déconnecté (${event.reason})" +
                                "\nen écoute sur ${localAddress()}" +
                                "\n\ncode d'appairage : $pairingCode"
                        )
                    }

                    is TransportServer.Event.Failed -> show("erreur : ${event.error.message}")
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
                Log.i(TAG, "HELLO de ${message.name}, protocole ${message.version}")
                show("connecté à ${message.name}, en attente du flux")
                withContext(Dispatchers.IO) { connection.send(info) }
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
                // Création synchrone : la frame suivante est la keyframe, et c'est la
                // seule avant longtemps. Un décodeur créé en différé la raterait et
                // resterait bloqué sur des frames intermédiaires inexploitables.
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

            is Message.Bye -> Log.i(TAG, "BYE, raison ${message.reason}")

            is Message.Unknown ->
                Log.i(TAG, "message de type inconnu 0x%02X ignoré".format(message.type))

            else -> Log.d(TAG, "reçu ${message::class.simpleName}")
        }
    }

    /**
     * Rapporte à intervalle fixe ce que la tablette a réellement affiché. C'est ce que le
     * Mac utilise pour ajuster son débit, et en dernier recours sa cadence.
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

    /** Au plus une demande par seconde : inutile d'en envoyer une par frame perdue. */
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
                    "décodeur pas prêt : config=${config != null} csd=${csd != null} surface=$surfaceReady",
                )
                return
            }

            awaitingKeyframe = true
            val created = VideoDecoder(
                surface = surfaceView.holder.surface,
                onFrameRendered = { latency -> overlay.onFrameRendered(latency) },
                onFrameDropped = { overlay.onFrameDropped() },
            )
            // Un décodeur qui refuse de se configurer ne doit pas emporter la connexion
            // avec lui : on reste connecté, écran noir, et on réessaiera au prochain
            // VIDEO_CONFIG.
            try {
                created.configure(config.width, config.height, csd, config.codec)
            } catch (error: Exception) {
                Log.e(TAG, "configuration du décodeur impossible", error)
                created.shutdown()
                parameterSets = null
                return
            }
            decoder = created
        }

        runOnUiThread {
            status.text = ""
            curtain.visibility = View.GONE
            overlay.transport = "USB"
        }
    }

    /** Garde le rapport d'aspect du flux, quitte à laisser des bandes noires. */
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

    private fun show(text: String) {
        runOnUiThread { status.text = if (text.isEmpty()) "" else "Sidebus\n\n$text" }
    }

    /** Adresse IPv4, affichée pour le repli manuel de la phase 6. */
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
    }
}
