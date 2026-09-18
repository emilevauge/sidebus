package app.sidebus.input

import android.view.MotionEvent
import android.view.View
import app.sidebus.protocol.InputEventKind
import app.sidebus.protocol.Message
import app.sidebus.protocol.MouseButton
import app.sidebus.transport.Connection
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.channels.BufferOverflow
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.launch

/**
 * Transforme les touchers de la vue vidéo en INPUT_EVENT.
 *
 * Les coordonnées sont normalisées sur la vue et pas sur l'écran : le flux est affiché à
 * son rapport d'aspect, avec des bandes noires possibles, et c'est l'image qui fait
 * référence.
 *
 * L'envoi passe par un canal consommé sur `Dispatchers.IO` : écrire sur le socket depuis
 * `onTouchEvent` bloquerait le thread principal, donc le rendu.
 */
class TouchSender(scope: CoroutineScope) {

    private var connection: Connection? = null

    private val events = Channel<Message.InputEvent>(
        capacity = 128,
        // Sous saturation, ce sont les déplacements les plus anciens qui perdent leur
        // intérêt. On ne bufferise jamais pour rattraper.
        onBufferOverflow = BufferOverflow.DROP_OLDEST,
    )

    init {
        scope.launch(Dispatchers.IO) {
            for (event in events) {
                runCatching { connection?.send(event) }
            }
        }
    }

    fun attach(connection: Connection?) {
        this.connection = connection
    }

    /** À brancher sur la vue qui affiche le flux. */
    fun onTouch(view: View, event: MotionEvent): Boolean {
        val kind = when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> InputEventKind.DOWN
            MotionEvent.ACTION_MOVE -> InputEventKind.MOVE
            MotionEvent.ACTION_UP -> InputEventKind.UP
            // Un geste annulé par le système se termine comme un relâchement, sinon le
            // Mac garde le bouton enfoncé.
            MotionEvent.ACTION_CANCEL -> InputEventKind.UP
            else -> return false
        }

        if (view.width == 0 || view.height == 0) return false

        val x = (event.x / view.width).coerceIn(0f, 1f)
        val y = (event.y / view.height).coerceIn(0f, 1f)

        events.trySend(
            Message.InputEvent(
                kind = kind,
                x = x,
                y = y,
                button = MouseButton.LEFT,
                timestamp = event.eventTime * 1_000,
            )
        )
        return true
    }
}
