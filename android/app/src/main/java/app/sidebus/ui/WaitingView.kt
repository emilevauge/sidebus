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
 * Écran affiché hors diffusion.
 *
 * C'est aussi le rideau qui masque la vidéo entre deux sessions. Surtout pas `lockCanvas`
 * sur la `SurfaceView` pour l'effacer : cela la connecte au producteur CPU et `MediaCodec`
 * ne peut plus s'y attacher ensuite, la configuration du décodeur échoue. Une vue opaque
 * posée par dessus règle le problème sans toucher à la surface.
 *
 * C'est elle qui porte l'appui long de désappairage, et non le texte : elle n'existe que
 * hors diffusion, donc elle ne peut pas avaler les touchers destinés à l'écran partagé.
 */
class WaitingView(context: Context) : FrameLayout(context) {

    private val etat: TextView
    private val detail: TextView
    private val code: TextView

    init {
        // Dégradé repris de la plaque de l'icône, pour que l'application et son écran
        // d'attente parlent la même langue.
        background = GradientDrawable(
            GradientDrawable.Orientation.TL_BR,
            intArrayOf(FOND_HAUT, FOND_BAS),
        )

        // Mise en page horizontale : l'écran est large et court, 369 dp de haut sur cette
        // tablette. Empiler le bus au dessus du texte ne rentre pas, le bloc déborde sur
        // le rappel du bas. La largeur, elle, ne manque pas.
        val rangee = LinearLayout(context).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
        }

        val bus = ImageView(context).apply {
            setImageResource(R.drawable.ic_launcher_foreground)
        }
        // Vue volontairement plus grande que le dessin voulu : le premier plan de l'icône
        // adaptative occupe moins de la moitié de sa toile, le reste étant la marge de
        // zone de sécurité du lanceur. Sans cette compensation le bus paraît minuscule.
        rangee.addView(
            bus,
            LinearLayout.LayoutParams(dp(190), dp(190)).apply { marginEnd = dp(8) },
        )

        val colonne = LinearLayout(context).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.START
        }

        val titre = TextView(context).apply {
            text = "Sidebus"
            setTextColor(TITRE)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 34f)
            typeface = Typeface.create("sans-serif-light", Typeface.NORMAL)
            letterSpacing = 0.06f
        }
        colonne.addView(titre, wrap().apply { bottomMargin = dp(14) })

        etat = TextView(context).apply {
            setTextColor(ETAT)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 17f)
        }
        colonne.addView(etat, wrap().apply { bottomMargin = dp(4) })

        detail = TextView(context).apply {
            setTextColor(DETAIL)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 14f)
            typeface = Typeface.MONOSPACE
        }
        colonne.addView(detail, wrap())

        // Le code d'appairage reste affiché tant qu'aucun Mac n'est connecté, et c'est
        // délibéré. Le Mac demande sa confirmation le premier, pendant le handshake TLS,
        // donc avant que la tablette n'ait rien montré. Sans ce code sous les yeux, on
        // accepterait sur le Mac à l'aveugle. La vérification que fait le dialogue de la
        // tablette ne remplace pas cette comparaison : elle porte sur un code transmis
        // dans le lien, donc falsifiable par celui dont on se protège. Voir PROTOCOL.md
        // section 7.
        code = TextView(context).apply {
            setTextColor(CODE)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 15f)
            typeface = Typeface.MONOSPACE
            letterSpacing = 0.18f
        }
        colonne.addView(code, wrap().apply { topMargin = dp(10) })

        rangee.addView(colonne, wrap())

        addView(
            rangee,
            LayoutParams(
                LayoutParams.WRAP_CONTENT,
                LayoutParams.WRAP_CONTENT,
                Gravity.CENTER,
            ),
        )

        val aide = TextView(context).apply {
            text = "Appui long pour oublier l'appairage"
            setTextColor(AIDE)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 12f)
            gravity = Gravity.CENTER
        }
        addView(
            aide,
            LayoutParams(
                LayoutParams.MATCH_PARENT,
                LayoutParams.WRAP_CONTENT,
                Gravity.BOTTOM or Gravity.CENTER_HORIZONTAL,
            ).apply { bottomMargin = dp(20) },
        )
    }

    /**
     * Met à jour ce qui est affiché.
     *
     * @param etat une phrase, l'état du lien.
     * @param detail une adresse ou une raison, en petit sous l'état. `null` pour rien.
     * @param code le code d'appairage à six chiffres. `null` dès qu'un Mac est connecté :
     *   à ce moment la comparaison a eu lieu, le laisser n'est plus que du bruit.
     */
    fun montrer(etat: String, detail: String? = null, code: String? = null) {
        this.etat.text = etat
        this.detail.text = detail ?: ""
        this.detail.visibility = if (detail.isNullOrEmpty()) View.GONE else View.VISIBLE
        this.code.text = if (code == null) "" else "code d'appairage  $code"
        this.code.visibility = if (code.isNullOrEmpty()) View.GONE else View.VISIBLE
    }

    private fun wrap() = LinearLayout.LayoutParams(
        LinearLayout.LayoutParams.WRAP_CONTENT,
        LinearLayout.LayoutParams.WRAP_CONTENT,
    )

    private fun dp(valeur: Int) = (valeur * resources.displayMetrics.density).toInt()

    private companion object {
        val FOND_HAUT = Color.parseColor("#22305F")
        val FOND_BAS = Color.parseColor("#0B1024")
        val TITRE = Color.parseColor("#F5F7FF")
        val ETAT = Color.parseColor("#A9B8E8")
        val DETAIL = Color.parseColor("#6D7CB4")
        val CODE = Color.parseColor("#FFC43D")
        val AIDE = Color.parseColor("#48548A")
    }
}
