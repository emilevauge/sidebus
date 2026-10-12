package app.sidebus.phone

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.net.wifi.WifiManager
import android.os.IBinder
import android.provider.ContactsContract.CommonDataKinds.Phone
import android.util.Log
import app.sidebus.DeviceDescriptor
import app.sidebus.R
import app.sidebus.pairing.DeviceIdentity
import app.sidebus.protocol.CallGrantStatus
import app.sidebus.protocol.Message
import app.sidebus.transport.Connection
import app.sidebus.transport.ServiceAdvertiser
import app.sidebus.transport.TransportServer
import javax.net.ssl.SSLServerSocketFactory
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/**
 * Carries the phone's calls to a paired Mac: the call channel of `protocol/PROTOCOL.md`
 * section 10, on its own port, in the background, screen off.
 *
 * Call audio itself comes from android/callbridge, a helper the Mac starts over USB, since
 * no app may reach it; this service relays between that helper and the Mac, over USB or
 * Wi-Fi. It also hands the Mac the address book, to complete names when dialing.
 */
class PhoneService : Service() {

    private val scope = CoroutineScope(Dispatchers.IO + Job())
    private lateinit var grants: CallGrants
    private lateinit var advertiser: ServiceAdvertiser
    private lateinit var helper: CallBridgeClient

    /** The Mac currently connected, once it proved it may use the calls. */
    @Volatile private var granted: Connection? = null
    @Volatile private var pendingGrant: Pair<Connection, String>? = null
    @Volatile private var peerName = "Mac"
    @Volatile private var lastStatus = -1
    @Volatile private var call: CallBridgeClient.Call? = null
    private var wifiLock: WifiManager.WifiLock? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        grants = CallGrants(this)
        helper = CallBridgeClient(this)
        advertiser = ServiceAdvertiser(this)
        createChannels()
        startForeground(
            NOTIFICATION_ID,
            statusNotification(),
            ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE,
        )
        val info = DeviceDescriptor.deviceInfo(this)
        advertiser.start(PORT, info, ServiceAdvertiser.CALL_SERVICE_TYPE)
        scope.launch { serve(info) }
        scope.launch { watchStatus() }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_ALLOW -> answerGrant(true)
            ACTION_DENY -> answerGrant(false)
        }
        return START_STICKY
    }

    override fun onDestroy() {
        advertiser.stop()
        endCall()
        scope.coroutineContext[Job]?.cancel()
        super.onDestroy()
    }

    // MARK: channel

    private suspend fun serve(info: Message.DeviceInfo) {
        val factory = DeviceIdentity.sslContext().serverSocketFactory as SSLServerSocketFactory
        TransportServer(port = PORT, serverSocketFactory = factory).run { event ->
            when (event) {
                is TransportServer.Event.Received -> handle(event.message, event.connection, info)
                is TransportServer.Event.Disconnected -> {
                    Log.i(TAG, "Mac gone: ${event.reason}")
                    granted = null
                    endCall()
                }
                else -> Unit
            }
        }
    }

    private fun handle(message: Message, connection: Connection, info: Message.DeviceInfo) {
        when (message) {
            is Message.Hello -> {
                peerName = message.name
                granted = null
                lastStatus = -1
                connection.send(info)
            }
            is Message.Ping -> connection.send(Message.Pong(message.timestamp))
            is Message.CallAccess -> access(message.token, connection)
            else -> if (granted === connection) handleGranted(message, connection)
        }
    }

    private fun handleGranted(message: Message, connection: Connection) {
        when (message) {
            is Message.CallStart -> startCall(connection)
            is Message.CallStop -> endCall()
            is Message.CallAudio -> runCatching { call?.output?.write(message.pcm) }
            is Message.ContactsRequest -> contacts()?.let { connection.send(Message.Contacts(it)) }
            else -> Unit
        }
    }

    // MARK: access

    private fun access(token: ByteArray, connection: Connection) {
        if (grants.isGranted(token)) {
            Log.i(TAG, "$peerName known, calls granted")
            granted = connection
            connection.send(Message.CallGrant(CallGrantStatus.GRANTED, token))
            sendStatus(connection, force = true)
            return
        }
        Log.i(TAG, "$peerName asks for the calls")
        pendingGrant = connection to peerName
        connection.send(Message.CallGrant(CallGrantStatus.WAITING, ByteArray(0)))
        notifyGrantRequest(peerName)
    }

    private fun answerGrant(allowed: Boolean) {
        getSystemService(NotificationManager::class.java).cancel(GRANT_NOTIFICATION_ID)
        val (connection, name) = pendingGrant ?: return
        pendingGrant = null
        scope.launch {
            runCatching {
                if (allowed) {
                    val token = grants.grant(name)
                    granted = connection
                    connection.send(Message.CallGrant(CallGrantStatus.GRANTED, token))
                    sendStatus(connection, force = true)
                } else {
                    connection.send(Message.CallGrant(CallGrantStatus.REFUSED, ByteArray(0)))
                }
            }
        }
    }

    // MARK: status

    private suspend fun watchStatus() {
        while (true) {
            granted?.let { runCatching { sendStatus(it, force = false) } }
            delay(3_000)
        }
    }

    private fun sendStatus(connection: Connection, force: Boolean) {
        var flags = 0
        if (helper.isRunning() || call != null) flags = flags or 0x01
        if (hasContacts()) flags = flags or 0x02
        if (flags == lastStatus && !force) return
        lastStatus = flags
        connection.send(Message.CallStatus(flags))
    }

    // MARK: call

    private fun startCall(connection: Connection) {
        endCall()
        val opened = runCatching { helper.call() }.getOrElse {
            Log.w(TAG, "call helper unreachable", it)
            connection.send(Message.CallStop)
            return
        }
        call = opened
        // Wi-Fi power saving delays packets by tens of milliseconds: off for the call.
        wifiLock = getSystemService(WifiManager::class.java)
            .createWifiLock(WifiManager.WIFI_MODE_FULL_LOW_LATENCY, "sidebus-call")
            .apply { acquire() }
        Log.i(TAG, "call audio started")
        scope.launch {
            val buffer = ByteArray(FRAME_BYTES)
            try {
                while (true) {
                    val read = opened.input.read(buffer)
                    if (read <= 0) break
                    connection.send(Message.CallAudio(buffer.copyOf(read)))
                }
            } catch (_: Exception) {
            }
            if (call === opened) {
                endCall()
                runCatching { connection.send(Message.CallStop) }
            }
        }
    }

    private fun endCall() {
        call?.close()
        call = null
        wifiLock?.let { if (it.isHeld) it.release() }
        wifiLock = null
    }

    // MARK: contacts

    private fun hasContacts() =
        checkSelfPermission(Manifest.permission.READ_CONTACTS) == PackageManager.PERMISSION_GRANTED

    private fun contacts(): ByteArray? {
        if (!hasContacts()) return null
        val text = StringBuilder()
        contentResolver.query(
            Phone.CONTENT_URI,
            arrayOf(Phone.DISPLAY_NAME, Phone.NUMBER, Phone.STARRED),
            null,
            null,
            null,
        )?.use { cursor ->
            while (cursor.moveToNext()) {
                val name = cursor.getString(0)?.replace('\t', ' ')?.replace('\n', ' ') ?: continue
                val number = cursor.getString(1) ?: continue
                text.append(name).append('\t').append(number).append('\t').append(cursor.getInt(2)).append('\n')
            }
        }
        return text.toString().toByteArray(Charsets.UTF_8)
    }

    // MARK: notifications

    private fun createChannels() {
        val manager = getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(
            NotificationChannel(CHANNEL_STATUS, "Calls on the Mac", NotificationManager.IMPORTANCE_MIN),
        )
        manager.createNotificationChannel(
            NotificationChannel(CHANNEL_GRANT, "Mac access requests", NotificationManager.IMPORTANCE_HIGH),
        )
    }

    private fun statusNotification(): Notification {
        val builder = Notification.Builder(this, CHANNEL_STATUS)
            .setSmallIcon(R.drawable.ic_launcher_monochrome)
            .setContentTitle("Sidebus carries calls to your Mac")
            .setOngoing(true)
        if (!hasContacts()) {
            builder.setContentText("Tap to let the Mac search your contacts")
            builder.setContentIntent(
                PendingIntent.getActivity(
                    this, 0, Intent(this, PermissionsActivity::class.java), PendingIntent.FLAG_IMMUTABLE,
                ),
            )
        }
        return builder.build()
    }

    private fun notifyGrantRequest(name: String) {
        fun action(action: String, title: String) = Notification.Action.Builder(
            null,
            title,
            PendingIntent.getService(
                this,
                action.hashCode(),
                Intent(this, PhoneService::class.java).setAction(action),
                PendingIntent.FLAG_IMMUTABLE,
            ),
        ).build()

        val notification = Notification.Builder(this, CHANNEL_GRANT)
            .setSmallIcon(R.drawable.ic_launcher_monochrome)
            .setContentTitle("Let $name carry your calls?")
            .setContentText("It will hear and speak in your calls, and search your contacts.")
            .addAction(action(ACTION_DENY, "Deny"))
            .addAction(action(ACTION_ALLOW, "Allow"))
            .setAutoCancel(true)
            .build()
        getSystemService(NotificationManager::class.java).notify(GRANT_NOTIFICATION_ID, notification)
    }

    companion object {
        /** Port of the call channel, apart from the display server's 27183. */
        const val PORT = 27185
        private const val FRAME_BYTES = 16_000 / 50 * 2
        private const val NOTIFICATION_ID = 1
        private const val GRANT_NOTIFICATION_ID = 2
        private const val CHANNEL_STATUS = "status"
        private const val CHANNEL_GRANT = "grant"
        private const val ACTION_ALLOW = "app.sidebus.phone.ALLOW"
        private const val ACTION_DENY = "app.sidebus.phone.DENY"
        private const val TAG = "SidebusPhone"

        /** Starts the service on a phone, and does nothing on a tablet without telephony. */
        fun start(context: Context) {
            if (!context.packageManager.hasSystemFeature(PackageManager.FEATURE_TELEPHONY)) return
            context.startForegroundService(Intent(context, PhoneService::class.java))
        }
    }
}

/** Brings the call service back after a restart or an update of the app. */
class PhoneServiceStarter : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        PhoneService.start(context)
    }
}
