package app.sidebus.pairing

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import java.math.BigInteger
import java.net.Socket
import java.security.KeyPairGenerator
import java.security.KeyStore
import java.security.MessageDigest
import java.security.Principal
import java.security.PrivateKey
import java.security.cert.X509Certificate
import java.util.Calendar
import java.util.UUID
import javax.net.ssl.SSLContext
import javax.net.ssl.SSLEngine
import javax.net.ssl.X509ExtendedKeyManager
import javax.security.auth.x500.X500Principal

/**
 * The tablet's identity: a persistent identifier, and a key pair with its self signed
 * certificate, generated on first launch and kept in the Android Keystore.
 *
 * No need for BouncyCastle: `KeyGenParameterSpec` has the Keystore produce a self signed
 * certificate, which is then read back from the entry.
 */
object DeviceIdentity {

    private const val ALIAS = "sidebus-tls"
    private const val KEYSTORE = "AndroidKeyStore"
    private const val PREFS = "sidebus"
    private const val KEY_UUID = "deviceUuid"

    /** Persistent identifier, shared by DEVICE_INFO and the `id` key of the mDNS advertisement. */
    fun uuid(context: Context): UUID {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        prefs.getString(KEY_UUID, null)?.let { return UUID.fromString(it) }

        val generated = UUID.randomUUID()
        prefs.edit().putString(KEY_UUID, generated.toString()).apply()
        return generated
    }

    /**
     * Erases the tablet's identity: new key pair, new certificate, new identifier. The Mac
     * will see it as an unknown device and ask for a pairing code again.
     */
    fun reset(context: Context) {
        runCatching {
            KeyStore.getInstance(KEYSTORE).apply { load(null) }.deleteEntry(ALIAS)
        }
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .edit()
            .remove(KEY_UUID)
            .apply()
    }

    fun certificate(): X509Certificate {
        entry()?.let { return it.certificate as X509Certificate }
        generate()
        return (entry() ?: error("certificate missing after generation"))
            .certificate as X509Certificate
    }

    /** SHA-256 of the certificate in DER form. */
    fun fingerprint(): ByteArray =
        MessageDigest.getInstance("SHA-256").digest(certificate().encoded)

    /** Six digit code derived from the fingerprint, see PROTOCOL.md section 7. */
    fun pairingCode(): String = pairingCode(fingerprint())

    fun pairingCode(fingerprint: ByteArray): String {
        val value = ((fingerprint[0].toLong() and 0xFF) shl 24) or
            ((fingerprint[1].toLong() and 0xFF) shl 16) or
            ((fingerprint[2].toLong() and 0xFF) shl 8) or
            (fingerprint[3].toLong() and 0xFF)
        return "%06d".format(value % 1_000_000)
    }

    /** First eight bytes of the fingerprint, in hex, for the `fp` TXT record. */
    fun fingerprintPrefix(): String =
        fingerprint().take(8).joinToString("") { "%02x".format(it) }

    /** Server side TLS 1.3 context, backed by the Keystore's non extractable key. */
    fun sslContext(): SSLContext {
        val entry = entry() ?: run {
            generate()
            entry() ?: error("key missing after generation")
        }
        val chain = arrayOf(entry.certificate as X509Certificate)
        val keyManager = KeystoreKeyManager(ALIAS, chain, entry.privateKey)

        return SSLContext.getInstance("TLSv1.3").apply {
            init(arrayOf(keyManager), null, null)
        }
    }

    private fun entry(): KeyStore.PrivateKeyEntry? {
        val keystore = KeyStore.getInstance(KEYSTORE).apply { load(null) }
        return keystore.getEntry(ALIAS, null) as? KeyStore.PrivateKeyEntry
    }

    private fun generate() {
        val start = Calendar.getInstance()
        val end = Calendar.getInstance().apply { add(Calendar.YEAR, 20) }

        val spec = KeyGenParameterSpec.Builder(
            ALIAS,
            KeyProperties.PURPOSE_SIGN or KeyProperties.PURPOSE_VERIFY,
        )
            .setDigests(
                // DIGEST_NONE is essential: in TLS 1.3 Conscrypt hashes the message itself
                // then asks for a raw ECDSA signature. Without this digest the Keystore
                // refuses the operation (INCOMPATIBLE_DIGEST) and the handshake dies without
                // an alert, which shows up as an "unexpected eof" on the client.
                KeyProperties.DIGEST_NONE,
                KeyProperties.DIGEST_SHA256,
                KeyProperties.DIGEST_SHA384,
                KeyProperties.DIGEST_SHA512,
            )
            .setCertificateSubject(X500Principal("CN=Sidebus"))
            .setCertificateSerialNumber(BigInteger.ONE)
            .setCertificateNotBefore(start.time)
            .setCertificateNotAfter(end.time)
            .build()

        KeyPairGenerator.getInstance(KeyProperties.KEY_ALGORITHM_EC, KEYSTORE).apply {
            initialize(spec)
            generateKeyPair()
        }
    }
}

/**
 * Exposes the Keystore's single key to the TLS engine. The private key is never extracted:
 * the object returned is a reference the Keystore uses to sign.
 */
private class KeystoreKeyManager(
    private val alias: String,
    private val chain: Array<X509Certificate>,
    private val key: PrivateKey,
) : X509ExtendedKeyManager() {

    override fun chooseServerAlias(keyType: String?, issuers: Array<out Principal>?, socket: Socket?) = alias

    override fun chooseEngineServerAlias(keyType: String?, issuers: Array<out Principal>?, engine: SSLEngine?) = alias

    override fun getServerAliases(keyType: String?, issuers: Array<out Principal>?) = arrayOf(alias)

    override fun getCertificateChain(alias: String?) = chain

    override fun getPrivateKey(alias: String?) = key

    // The Mac presents no certificate: nothing to choose on the client side.
    override fun chooseClientAlias(keyType: Array<out String>?, issuers: Array<out Principal>?, socket: Socket?) = null

    override fun getClientAliases(keyType: String?, issuers: Array<out Principal>?) = null
}
