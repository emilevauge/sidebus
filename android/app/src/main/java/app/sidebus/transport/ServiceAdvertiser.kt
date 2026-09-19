package app.sidebus.transport

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.util.Log
import app.sidebus.pairing.DeviceIdentity
import app.sidebus.protocol.Message

/**
 * Advertises the tablet on the local network. The tablet is the server: the Mac browses the
 * network and connects to what it finds.
 *
 * The advertisement only lives while the app is in the foreground, so as not to clutter the
 * network when it can display nothing.
 */
class ServiceAdvertiser(private val context: Context) {

    private val manager = context.getSystemService(NsdManager::class.java)
    private var listener: NsdManager.RegistrationListener? = null

    fun start(port: Int, info: Message.DeviceInfo) {
        if (listener != null) return

        val service = NsdServiceInfo().apply {
            // The name has to be recognisable to the user in the Mac's menu.
            serviceName = info.name
            serviceType = SERVICE_TYPE
            setPort(port)
            setAttribute("v", PROTOCOL_VERSION.toString())
            setAttribute("id", info.uuid.toString())
            setAttribute("w", info.width.toString())
            setAttribute("h", info.height.toString())
            setAttribute("d", info.density.toString())
            setAttribute("c", info.codecs.toString())
            // Lets the Mac recognise an already paired tablet before it even opens the
            // connection.
            setAttribute("fp", DeviceIdentity.fingerprintPrefix())
        }

        val registration = object : NsdManager.RegistrationListener {
            override fun onServiceRegistered(info: NsdServiceInfo) {
                Log.i(TAG, "advertised over mDNS as \"${info.serviceName}\"")
            }

            override fun onRegistrationFailed(info: NsdServiceInfo, errorCode: Int) {
                Log.e(TAG, "mDNS advertisement refused, code $errorCode")
            }

            override fun onServiceUnregistered(info: NsdServiceInfo) {
                Log.i(TAG, "mDNS advertisement withdrawn")
            }

            override fun onUnregistrationFailed(info: NsdServiceInfo, errorCode: Int) {
                Log.w(TAG, "withdrawing the advertisement refused, code $errorCode")
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
