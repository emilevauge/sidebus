package app.sidebus.ui

import android.content.Context
import android.graphics.Color
import android.view.Gravity
import android.widget.TextView

/**
 * Counters shown on demand: fps, decoding latency, bitrate, dropped frames, active
 * transport.
 *
 * Refreshed at 4 Hz rather than on every frame: updating an observed view 60 times a second
 * costs more than the rest of the pipeline, as measured on the Mac side.
 */
class DebugOverlay(context: Context) : TextView(context) {

    private var framesInWindow = 0
    private var bytesInWindow = 0L
    private var latencySum = 0L
    private var latencyCount = 0

    private var droppedTotal = 0
    private var receivedTotal = 0

    /// Counters of the current STATS window, reset on every send.
    private var statsReceived = 0
    private var statsDropped = 0

    var transport: String = "USB"

    private var windowStart = System.nanoTime()

    init {
        setTextColor(Color.GREEN)
        setBackgroundColor(Color.argb(140, 0, 0, 0))
        textSize = 12f
        setPadding(16, 12, 16, 12)
        gravity = Gravity.START
        text = "waiting"
    }

    /** Frame received from the link and pushed to the decoder. */
    fun onFrameReceived(bytes: Int) {
        receivedTotal += 1
        statsReceived += 1
        bytesInWindow += bytes
        refreshIfDue()
    }

    /** Frame actually displayed. This is what gives the real fps. */
    fun onFrameRendered(latencyMillis: Long) {
        framesInWindow += 1
        latencySum += latencyMillis
        latencyCount += 1
        refreshIfDue()
    }

    fun onFrameDropped() {
        droppedTotal += 1
        statsDropped += 1
        refreshIfDue()
    }

    private fun refreshIfDue() {
        val now = System.nanoTime()
        val elapsedNanos = now - windowStart
        if (elapsedNanos < WINDOW_NANOS) return

        val seconds = elapsedNanos / 1_000_000_000.0
        val fps = framesInWindow / seconds
        val megabitsPerSecond = bytesInWindow * 8 / seconds / 1_000_000
        val latency = if (latencyCount > 0) latencySum / latencyCount else 0

        val summary = buildString {
            append("%.0f fps".format(fps))
            append("  %.1f Mbit/s".format(megabitsPerSecond))
            append("  decode %d ms".format(latency))
            append("  received %d".format(receivedTotal))
            append("  dropped %d".format(droppedTotal))
            append("  $transport")
        }

        framesInWindow = 0
        bytesInWindow = 0
        latencySum = 0
        latencyCount = 0
        windowStart = now

        post { text = summary }
    }

    /** Counters of the window that elapsed, for the STATS message, then reset. */
    fun takeStats(): Pair<Int, Int> {
        val snapshot = statsReceived to statsDropped
        statsReceived = 0
        statsDropped = 0
        return snapshot
    }

    companion object {
        private const val WINDOW_NANOS = 250_000_000L
    }
}
