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

/** Une connexion établie. L'écriture est sérialisée, la lecture appartient au serveur. */
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
 * La tablette écoute, le Mac se connecte. Vrai en USB comme en Wi-Fi, voir PLAN.md
 * section 2.
 *
 * Une seule connexion à la fois : un deuxième client attend que le premier parte.
 * En clair pour l'instant, TLS arrive en phase 6.
 */
class TransportServer(
    private val port: Int = DEFAULT_PORT,
    /**
     * Fabrique de sockets. En TLS, le chiffrement est actif dans les deux transports :
     * un seul chemin de code à maintenir et à tester, et le surcoût de TLS 1.3 est
     * négligeable devant l'encodage vidéo.
     */
    private val serverSocketFactory: SSLServerSocketFactory? = null,
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
                // Le handshake a son propre délai, bien plus long. Le Mac affiche le code
                // d'appairage pendant la vérification du certificat, donc au milieu du
                // handshake, et attend une réponse humaine. Avec le délai de lecture
                // ordinaire, la connexion mourait avant que l'utilisateur ait eu le temps
                // de comparer les deux codes.
                socket.soTimeout = HANDSHAKE_TIMEOUT_MS
                if (socket is javax.net.ssl.SSLSocket) {
                    try {
                        socket.startHandshake()
                        Log.i(
                            TAG,
                            "handshake TLS : ${socket.session.protocol} ${socket.session.cipherSuite}",
                        )
                    } catch (error: Exception) {
                        Log.e(TAG, "handshake TLS échoué", error)
                        var cause: Throwable? = error.cause
                        while (cause != null) {
                            Log.e(TAG, "  cause : $cause")
                            cause = cause.cause
                        }
                        runCatching { socket.close() }
                        continue
                    }
                }
                // Handshake passé : on revient au délai ordinaire. Sans lui, un Mac qui
                // disparaît sans fermer proprement, coupure Wi-Fi ou veille, laisse la
                // boucle bloquée pour toujours, et le serveur n'accepte plus personne
                // puisqu'il ne tient qu'une connexion à la fois.
                socket.soTimeout = READ_TIMEOUT_MS
                val connection = Connection(socket)
                onEvent(Event.Connected(connection.remote))

                val reason = try {
                    readLoop(socket, connection, onEvent)
                    "fermée par le pair"
                } catch (timeout: java.net.SocketTimeoutException) {
                    "silence de plus de ${READ_TIMEOUT_MS / 1000} s"
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
            // Le Mac ne présente pas de certificat : l'authentification est à sens unique,
            // c'est son épinglage qui authentifie la tablette.
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
            // Lecture directe dans le tampon du décodeur : pas de tableau intermédiaire.
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

        /// Le temps d'aller chercher la tablette dans l'autre pièce et de comparer les
        /// codes, des deux côtés. Aligné sur le délai de PAIR_RESULT du protocole.
        private const val HANDSHAKE_TIMEOUT_MS = 130_000

        private const val TAG = "Sidebus"
    }
}
