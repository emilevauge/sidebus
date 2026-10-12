package app.sidebus.phone

import android.net.LocalSocket
import android.net.LocalSocketAddress
import java.io.InputStream
import java.io.OutputStream

/**
 * The app's side of android/callbridge, the helper started over adb that alone reaches
 * call audio. It listens on the abstract socket sidebus-call and checks that the caller is
 * this app.
 */
object CallBridgeClient {
    private const val SOCKET = "sidebus-call"

    /** True when the helper runs. It does from a USB plug until the phone restarts. */
    fun isRunning(): Boolean = runCatching {
        LocalSocket().use { socket ->
            socket.connect(LocalSocketAddress(SOCKET))
            socket.soTimeout = 1_000
            socket.outputStream.write('P'.code)
            socket.inputStream.read() == 'K'.code
        }
    }.getOrDefault(false)

    /** Opens a call: read the other party from `input`, write the Mac's voice to `output`. */
    class Call : AutoCloseable {
        private val socket = LocalSocket().apply {
            connect(LocalSocketAddress(SOCKET))
            outputStream.write('C'.code)
        }
        val input: InputStream = socket.inputStream
        val output: OutputStream = socket.outputStream

        override fun close() {
            runCatching { socket.shutdownInput() }
            runCatching { socket.shutdownOutput() }
            runCatching { socket.close() }
        }
    }
}
