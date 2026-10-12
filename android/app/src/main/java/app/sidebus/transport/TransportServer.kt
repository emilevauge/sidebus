package app.sidebus.transport

import android.util.Log
import app.sidebus.protocol.Message
import app.sidebus.protocol.MessageCodec
import app.sidebus.protocol.MessageDecoder
import java.io.OutputStream
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import javax.net.ssl.SSLServerSocket
import javax.net.ssl.SSLServerSocketFactory
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.isActive
import kotlinx.coroutines.withContext

/** An established connection. Writing is serialised, reading belongs to the server. */
class Connection(private val socket: Socket) {
    private val output: OutputStream = socket.getOutputStream()
    private val writeLock = Any()

    val remote: String = socket.inetAddress?.hostAddress ?: "inconnu"

    fun send(message: Message) {
        synchronized(writeLock) {
            output.write(MessageCodec.encode(message))
            output.flush()
        }
    }

    fun close() {
        runCatching { socket.close() }
    }
}

/**
 * The tablet listens, the Mac connects. True on USB as on Wi-Fi, see
 * `protocol/PROTOCOL.md` section 1.
 *
 * One connection at a time: a second client waits for the first to leave.
 */
class TransportServer(
    private val port: Int = DEFAULT_PORT,
    /**
     * Socket factory. Encryption is on in both transports: one code path to maintain and to
     * test, and the cost of TLS 1.3 is negligible next to video encoding.
     */
    private val serverSocketFactory: SSLServerSocketFactory? = null,
    /** Silence after which the Mac counts as gone. */
    private val readTimeoutMs: Int = READ_TIMEOUT_MS,
) {

    sealed class Event {
        data class Listening(val port: Int) : Event()
        data class Connected(val remote: String) : Event()
        data class Received(val message: Message, val connection: Connection) : Event()
        data class Disconnected(val reason: String) : Event()
        data class Failed(val error: Throwable) : Event()
    }

    suspend fun run(onEvent: suspend (Event) -> Unit) = withContext(Dispatchers.IO) {
        createServerSocket().use { server ->
            server.reuseAddress = true
            server.bind(InetSocketAddress(port))
            onEvent(Event.Listening(port))

            while (currentCoroutineContext().isActive) {
                val socket = try {
                    server.accept()
                } catch (error: Exception) {
                    if (!currentCoroutineContext().isActive) break
                    onEvent(Event.Failed(error))
                    continue
                }

                socket.tcpNoDelay = true
                // The handshake has a deadline of its own, far longer. The Mac shows the pairing
                // code while verifying the certificate, so in the middle of the handshake,
                // and waits for a human answer. With the ordinary read timeout, the
                // connection died before the user had time to compare the two codes.
                socket.soTimeout = HANDSHAKE_TIMEOUT_MS
                if (socket is javax.net.ssl.SSLSocket) {
                    try {
                        socket.startHandshake()
                        Log.i(
                            TAG,
                            "handshake TLS : ${socket.session.protocol} ${socket.session.cipherSuite}",
                        )
                    } catch (error: Exception) {
                        Log.e(TAG, "TLS handshake failed", error)
                        var cause: Throwable? = error.cause
                        while (cause != null) {
                            Log.e(TAG, "  cause: $cause")
                            cause = cause.cause
                        }
                        runCatching { socket.close() }
                        continue
                    }
                }
                // Handshake through: back to the ordinary timeout. Without it a Mac that vanishes
                // without closing cleanly, a Wi-Fi cut or a sleep, leaves the loop blocked
                // forever, and the server accepts nobody since it holds one connection at a
                // time.
                socket.soTimeout = readTimeoutMs
                val connection = Connection(socket)
                onEvent(Event.Connected(connection.remote))

                val reason = try {
                    readLoop(socket, connection, onEvent)
                    "closed by the peer"
                } catch (timeout: java.net.SocketTimeoutException) {
                    "silent for more than ${readTimeoutMs / 1000} s"
                } catch (error: Exception) {
                    Log.w(TAG, "connexion interrompue", error)
                    error.message ?: error.javaClass.simpleName
                } finally {
                    connection.close()
                }
                onEvent(Event.Disconnected(reason))
            }
        }
    }

    private fun createServerSocket(): ServerSocket {
        val factory = serverSocketFactory ?: return ServerSocket()
        return (factory.createServerSocket() as SSLServerSocket).apply {
            enabledProtocols = arrayOf("TLSv1.3")
            // The Mac presents no certificate: authentication goes one way, and its pinning is
            // what authenticates the tablet.
            needClientAuth = false
            wantClientAuth = false
        }
    }

    private suspend fun readLoop(
        socket: Socket,
        connection: Connection,
        onEvent: suspend (Event) -> Unit,
    ) {
        val input = socket.getInputStream()
        val decoder = MessageDecoder()

        while (currentCoroutineContext().isActive) {
            // Read straight into the decoder's buffer: no intermediate array.
            val read = decoder.readFrom(input)
            if (read < 0) return
            if (read == 0) continue

            while (true) {
                val message = decoder.next() ?: break
                onEvent(Event.Received(message, connection))
            }
        }
    }

    companion object {
        const val DEFAULT_PORT = 27183

        /**
         * Le Mac envoie un PING par seconde : plus de dix secondes de silence veut dire
         * que le lien est mort, quoi qu'en dise le socket.
         */
        private const val READ_TIMEOUT_MS = 10_000

        /** Time enough to fetch the tablet from the other room and compare the codes, on
         * both sides. Aligned on the protocol's PAIR_RESULT deadline. */
        private const val HANDSHAKE_TIMEOUT_MS = 130_000

        private const val TAG = "Sidebus"
    }
}
