package app.sidebus.ui

import android.content.Context
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.util.TypedValue
import android.view.Gravity
import android.view.View
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.TextView
import app.sidebus.R

/**
 * The screen shown while nothing is streaming.
 *
 * It doubles as the curtain hiding the video between two sessions. Never `lockCanvas` on the
 * `SurfaceView` to clear it: that connects it to the CPU producer and `MediaCodec` can no
 * longer attach, so configuring the decoder fails. An opaque view laid on top solves it
 * without touching the surface.
 *
 * It carries the long press that unpairs, rather than the text: it only exists outside
 * streaming, so it cannot swallow touches meant for the shared screen.
 */
class WaitingView(context: Context) : FrameLayout(context) {

    private val state: TextView
    private val detail: TextView
    private val code: TextView

    init {
        // Gradient taken from the icon's plate, so the app and its waiting screen speak the
        // same language.
        background = GradientDrawable(
            GradientDrawable.Orientation.TL_BR,
            intArrayOf(BACKGROUND_TOP, BACKGROUND_BOTTOM),
        )

        // Horizontal layout: the screen is wide and short, 369 dp tall on this tablet.
        // Stacking the bus above the text does not fit, the block spills onto the hint at
        // the bottom. Width, on the other hand, is plentiful.
        val row = LinearLayout(context).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
        }

        val bus = ImageView(context).apply {
            setImageResource(R.drawable.ic_launcher_foreground)
        }
        // A view deliberately larger than the wanted drawing: the adaptive icon's foreground
        // fills less than half its canvas, the rest being the launcher's safe zone margin.
        // Without that compensation the bus looks minuscule.
        row.addView(
            bus,
            LinearLayout.LayoutParams(dp(190), dp(190)).apply { marginEnd = dp(8) },
        )

        val column = LinearLayout(context).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.START
        }

        val title = TextView(context).apply {
            text = "Sidebus"
            setTextColor(TITLE)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 34f)
            typeface = Typeface.create("sans-serif-light", Typeface.NORMAL)
            letterSpacing = 0.06f
        }
        column.addView(title, wrap().apply { bottomMargin = dp(14) })

        state = TextView(context).apply {
            setTextColor(STATE)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 17f)
        }
        column.addView(state, wrap().apply { bottomMargin = dp(4) })

        detail = TextView(context).apply {
            setTextColor(DETAIL)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 14f)
            typeface = Typeface.MONOSPACE
        }
        column.addView(detail, wrap())

        // The pairing code stays on screen while no Mac is connected, and that is deliberate.
        // The Mac asks for its confirmation first, during the TLS handshake, so before the
        // tablet has shown anything. Without that code in sight you would accept on the Mac
        // blind. The check the tablet's dialog performs does not replace this comparison: it
        // works on a code that travelled through the link, so it can be forged by the very
        // party you are guarding against. See PROTOCOL.md section 7.
        code = TextView(context).apply {
            setTextColor(CODE)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 15f)
            typeface = Typeface.MONOSPACE
            letterSpacing = 0.18f
        }
        column.addView(code, wrap().apply { topMargin = dp(10) })

        row.addView(column, wrap())

        addView(
            row,
            LayoutParams(
                LayoutParams.WRAP_CONTENT,
                LayoutParams.WRAP_CONTENT,
                Gravity.CENTER,
            ),
        )

        val hint = TextView(context).apply {
            text = "Long press to forget the pairing"
            setTextColor(HINT)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 12f)
            gravity = Gravity.CENTER
        }
        addView(
            hint,
            LayoutParams(
                LayoutParams.MATCH_PARENT,
                LayoutParams.WRAP_CONTENT,
                Gravity.BOTTOM or Gravity.CENTER_HORIZONTAL,
            ).apply { bottomMargin = dp(20) },
        )
    }

    /**
     * Updates what is displayed.
     *
     * @param state one sentence, the state of the link.
     * @param detail an address or a reason, small under the state. `null` for nothing.
     * @param code the six digit pairing code. `null` as soon as a Mac is connected: by then
     *   the comparison has happened, and leaving it there is only noise.
     */
    fun show(state: String, detail: String? = null, code: String? = null) {
        this.state.text = state
        this.detail.text = detail ?: ""
        this.detail.visibility = if (detail.isNullOrEmpty()) View.GONE else View.VISIBLE
        this.code.text = if (code == null) "" else "pairing code  $code"
        this.code.visibility = if (code.isNullOrEmpty()) View.GONE else View.VISIBLE
    }

    private fun wrap() = LinearLayout.LayoutParams(
        LinearLayout.LayoutParams.WRAP_CONTENT,
        LinearLayout.LayoutParams.WRAP_CONTENT,
    )

    private fun dp(value: Int) = (value * resources.displayMetrics.density).toInt()

    private companion object {
        val BACKGROUND_TOP = Color.parseColor("#22305F")
        val BACKGROUND_BOTTOM = Color.parseColor("#0B1024")
        val TITLE = Color.parseColor("#F5F7FF")
        val STATE = Color.parseColor("#A9B8E8")
        val DETAIL = Color.parseColor("#6D7CB4")
        val CODE = Color.parseColor("#FFC43D")
        val HINT = Color.parseColor("#48548A")
    }
}
