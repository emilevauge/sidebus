package app.sidebus.phone

import android.app.Notification
import android.content.ComponentName
import android.content.Context
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import android.telecom.TelecomManager

/**
 * Reads who calls from the dialer's incoming call notification: the phone's call screen
 * names businesses and spam it looked up online, which Bluetooth never passes on. Needs
 * the notification access the user grants in the system settings.
 */
class CallerIdListener : NotificationListenerService() {

    override fun onNotificationPosted(sbn: StatusBarNotification) {
        val notification = sbn.notification ?: return
        if (notification.category != Notification.CATEGORY_CALL) return
        val dialer = getSystemService(TelecomManager::class.java)?.defaultDialerPackage
        if (dialer != null && sbn.packageName != dialer) return
        val title = notification.extras.getCharSequence(Notification.EXTRA_TITLE)?.toString() ?: return
        val text = notification.extras.getCharSequence(Notification.EXTRA_TEXT)?.toString() ?: ""
        latest = Caller(title, text, System.currentTimeMillis())
        onCaller?.invoke(latest!!)
    }

    data class Caller(val title: String, val text: String, val at: Long) {
        fun encoded(): ByteArray = "$title\n$text".toByteArray(Charsets.UTF_8)
    }

    companion object {
        /** The last caller seen, for a Mac that connects once the call already rings. */
        @Volatile var latest: Caller? = null
        @Volatile var onCaller: ((Caller) -> Unit)? = null

        fun isEnabled(context: Context): Boolean {
            val manager = context.getSystemService(android.app.NotificationManager::class.java)
            return manager.isNotificationListenerAccessGranted(ComponentName(context, CallerIdListener::class.java))
        }
    }
}
