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
 * Turns touches on the video view into INPUT_EVENT messages.
 *
 * Coordinates are normalised against the view and not the screen: the stream keeps its aspect
 * ratio, possibly with black bars, so the picture is the reference.
 *
 * Sending goes through a channel consumed on `Dispatchers.IO`: writing to the socket from
 * `onTouchEvent` would block the main thread, and with it the rendering.
 */
class TouchSender(scope: CoroutineScope) {

    private var connection: Connection? = null

    private val events = Channel<Message.InputEvent>(
        capacity = 128,
        // Under saturation it is the oldest moves that stop mattering. Never buffer to
        // catch up.
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

    /** To be attached to the view showing the stream. */
    fun onTouch(view: View, event: MotionEvent): Boolean {
        val kind = when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> InputEventKind.DOWN
            MotionEvent.ACTION_MOVE -> InputEventKind.MOVE
            MotionEvent.ACTION_UP -> InputEventKind.UP
            // A gesture the system cancels ends as a release, otherwise the Mac keeps the
            // button down.
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
