package app.sidebus.phone

import android.content.Context
import java.io.DataInputStream
import java.io.InputStream
import java.io.OutputStream
import java.net.InetAddress
import java.net.Socket
import java.security.MessageDigest
import java.security.SecureRandom
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec

/**
 * The app's side of android/callbridge, the helper started over adb that alone reaches
 * call audio. It listens on 127.0.0.1:27186, where any app could connect too, so both
 * ends prove they know the secret the Mac drew for this helper: see CallBridge.java.
 */
class CallBridgeClient(context: Context) {
    private val preferences = context.getSharedPreferences("call-helper", Context.MODE_PRIVATE)

    /** Records the secret of the helper the Mac just started or found running. */
    fun setSecret(hex: String) {
        preferences.edit().putString(KEY, hex).apply()
    }

    private fun secret(): ByteArray? =
        preferences.getString(KEY, null)?.chunked(2)?.map { it.toInt(16).toByte() }?.toByteArray()

    /** True when the helper runs. It does from a USB plug until the phone restarts. */
    fun isRunning(): Boolean = runCatching {
        open('P').use { socket -> socket.getInputStream().read() == 'K'.code }
    }.getOrDefault(false)

    /** Opens a call: read the other party from `input`, write the Mac's voice to `output`. */
    fun call(): Call = Call(open('C'))

    class Call(private val socket: Socket) : AutoCloseable {
        val input: InputStream = socket.getInputStream()
        val output: OutputStream = socket.getOutputStream()

        override fun close() {
            runCatching { socket.close() }
        }
    }

    private fun open(command: Char): Socket {
        val secret = secret() ?: error("no helper secret yet")
        // A bounded connect: an unbounded one hung for most of a minute when the helper's
        // queue was full.
        val socket = Socket()
        try {
            socket.connect(java.net.InetSocketAddress(InetAddress.getLoopbackAddress(), PORT), 1_000)
            socket.tcpNoDelay = true
            socket.soTimeout = 2_000
            val input = DataInputStream(socket.getInputStream())
            val output = socket.getOutputStream()
            val theirs = ByteArray(16).also { input.readFully(it) }
            val ours = ByteArray(16).also { SecureRandom().nextBytes(it) }
            output.write(hmac(secret, "app", theirs) + ours)
            val proof = ByteArray(32).also { input.readFully(it) }
            // A process holding the port without the secret is not the helper: it gets
            // neither the call nor the microphone.
            check(MessageDigest.isEqual(proof, hmac(secret, "helper", ours))) { "not the call helper" }
            output.write(command.code)
            socket.soTimeout = 0
            return socket
        } catch (error: Exception) {
            socket.close()
            throw error
        }
    }

    private fun hmac(secret: ByteArray, label: String, nonce: ByteArray): ByteArray =
        Mac.getInstance("HmacSHA256").run {
            init(SecretKeySpec(secret, "HmacSHA256"))
            update(label.toByteArray())
            doFinal(nonce)
        }

    companion object {
        private const val PORT = 27186
        private const val KEY = "secret"
    }
}
