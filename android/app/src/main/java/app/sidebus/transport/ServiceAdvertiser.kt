package app.sidebus.transport

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.util.Log
import app.sidebus.pairing.DeviceIdentity
import app.sidebus.protocol.Message

/**
 * Annonce la tablette sur le réseau local. C'est elle le serveur : le Mac parcourt le
 * réseau et se connecte à ce qu'il trouve.
 *
 * L'annonce ne vit que quand l'application est au premier plan, pour ne pas encombrer le
 * réseau quand elle ne peut rien afficher.
 */
class ServiceAdvertiser(private val context: Context) {

    private val manager = context.getSystemService(NsdManager::class.java)
    private var listener: NsdManager.RegistrationListener? = null

    fun start(port: Int, info: Message.DeviceInfo) {
        if (listener != null) return

        val service = NsdServiceInfo().apply {
            // Le nom doit être reconnaissable par l'utilisateur dans le menu du Mac.
            serviceName = info.name
            serviceType = SERVICE_TYPE
            setPort(port)
            setAttribute("v", PROTOCOL_VERSION.toString())
            setAttribute("id", info.uuid.toString())
            setAttribute("w", info.width.toString())
            setAttribute("h", info.height.toString())
            setAttribute("d", info.density.toString())
            setAttribute("c", info.codecs.toString())
            // Permet au Mac de reconnaître une tablette déjà appairée avant même
            // d'ouvrir la connexion.
            setAttribute("fp", DeviceIdentity.fingerprintPrefix())
        }

        val registration = object : NsdManager.RegistrationListener {
            override fun onServiceRegistered(info: NsdServiceInfo) {
                Log.i(TAG, "annoncé en mDNS sous « ${info.serviceName} »")
            }

            override fun onRegistrationFailed(info: NsdServiceInfo, errorCode: Int) {
                Log.e(TAG, "annonce mDNS refusée, code $errorCode")
            }

            override fun onServiceUnregistered(info: NsdServiceInfo) {
                Log.i(TAG, "annonce mDNS retirée")
            }

            override fun onUnregistrationFailed(info: NsdServiceInfo, errorCode: Int) {
                Log.w(TAG, "retrait de l'annonce refusé, code $errorCode")
            }
        }

        listener = registration
        manager.registerService(service, NsdManager.PROTOCOL_DNS_SD, registration)
    }

    fun stop() {
        listener?.let { runCatching { manager.unregisterService(it) } }
        listener = null
    }

    companion object {
        const val SERVICE_TYPE = "_sidebus._tcp"
        const val PROTOCOL_VERSION = 1
        private const val TAG = "Sidebus"
    }
}
