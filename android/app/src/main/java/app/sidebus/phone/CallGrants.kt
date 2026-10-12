package app.sidebus.phone

import android.content.Context
import java.security.MessageDigest
import java.security.SecureRandom

/**
 * Macs the user allowed to carry their calls, each known by the token it received. Only
 * a hash of each token is kept: the phone only needs to recognise one.
 */
class CallGrants(context: Context) {
    private val preferences = context.getSharedPreferences("call-grants", Context.MODE_PRIVATE)

    fun isGranted(token: ByteArray): Boolean =
        token.size == TOKEN_SIZE && preferences.contains(hash(token))

    /** Records a new grant for `macName` and returns its token. */
    fun grant(macName: String): ByteArray {
        val token = ByteArray(TOKEN_SIZE).also { SecureRandom().nextBytes(it) }
        preferences.edit().putString(hash(token), macName).apply()
        return token
    }

    fun revokeAll() {
        preferences.edit().clear().apply()
    }

    private fun hash(token: ByteArray): String =
        MessageDigest.getInstance("SHA-256").digest(token).joinToString("") { "%02x".format(it) }

    companion object {
        const val TOKEN_SIZE = 32
    }
}
