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
 * Identité de la tablette : un identifiant persistant, et une paire de clés avec son
 * certificat auto signé, générés au premier lancement et conservés dans l'Android
 * Keystore.
 *
 * Pas besoin de BouncyCastle : `KeyGenParameterSpec` fait produire au Keystore un
 * certificat auto signé qu'on relit ensuite depuis l'entrée.
 */
object DeviceIdentity {

    private const val ALIAS = "sidebus-tls"
    private const val KEYSTORE = "AndroidKeyStore"
    private const val PREFS = "sidebus"
    private const val KEY_UUID = "deviceUuid"

    /** Identifiant persistant, partagé par DEVICE_INFO et la clé `id` de l'annonce mDNS. */
    fun uuid(context: Context): UUID {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        prefs.getString(KEY_UUID, null)?.let { return UUID.fromString(it) }

        val generated = UUID.randomUUID()
        prefs.edit().putString(KEY_UUID, generated.toString()).apply()
        return generated
    }

    /**
     * Efface l'identité de la tablette : nouvelle paire de clés, nouveau certificat,
     * nouvel identifiant. Le Mac la verra comme un appareil inconnu et redemandera le
     * code d'appairage.
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
        return (entry() ?: error("certificat introuvable après génération"))
            .certificate as X509Certificate
    }

    /** SHA-256 du certificat au format DER. */
    fun fingerprint(): ByteArray =
        MessageDigest.getInstance("SHA-256").digest(certificate().encoded)

    /** Code à six chiffres dérivé de l'empreinte, voir PROTOCOL.md section 7. */
    fun pairingCode(): String = pairingCode(fingerprint())

    fun pairingCode(fingerprint: ByteArray): String {
        val value = ((fingerprint[0].toLong() and 0xFF) shl 24) or
            ((fingerprint[1].toLong() and 0xFF) shl 16) or
            ((fingerprint[2].toLong() and 0xFF) shl 8) or
            (fingerprint[3].toLong() and 0xFF)
        return "%06d".format(value % 1_000_000)
    }

    /** Huit premiers octets de l'empreinte, en hexadécimal, pour le TXT `fp`. */
    fun fingerprintPrefix(): String =
        fingerprint().take(8).joinToString("") { "%02x".format(it) }

    /** Contexte TLS 1.3 côté serveur, adossé à la clé non extractible du Keystore. */
    fun sslContext(): SSLContext {
        val entry = entry() ?: run {
            generate()
            entry() ?: error("clé introuvable après génération")
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
                // DIGEST_NONE est indispensable : en TLS 1.3, Conscrypt hache lui même le
                // message puis demande une signature ECDSA brute. Sans ce digest, le
                // Keystore refuse l'opération (INCOMPATIBLE_DIGEST) et le handshake meurt
                // sans alerte, ce qui donne un « unexpected eof » côté client.
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
 * Expose l'unique clé du Keystore au moteur TLS. La clé privée n'est jamais extraite :
 * l'objet renvoyé est une référence que le Keystore utilise pour signer.
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

    // Le Mac ne présente pas de certificat : rien à choisir côté client.
    override fun chooseClientAlias(keyType: Array<out String>?, issuers: Array<out Principal>?, socket: Socket?) = null

    override fun getClientAliases(keyType: String?, issuers: Array<out Principal>?) = null
}
