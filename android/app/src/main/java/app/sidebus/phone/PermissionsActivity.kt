package app.sidebus.phone

import android.Manifest
import android.app.Activity
import android.content.pm.PackageManager
import android.os.Bundle

/**
 * Starts the call service, asks for what it needs (contacts, notifications), and closes.
 * Opened from the service's notification.
 */
class PermissionsActivity : Activity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        PhoneService.start(this)
        val missing = arrayOf(Manifest.permission.READ_CONTACTS, Manifest.permission.POST_NOTIFICATIONS)
            .filter { checkSelfPermission(it) != PackageManager.PERMISSION_GRANTED }
        if (missing.isEmpty()) {
            askNotificationAccess()
            finish()
        } else {
            requestPermissions(missing.toTypedArray(), 0)
        }
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        PhoneService.start(this)
        askNotificationAccess()
        finish()
    }

    /** Caller names come from the dialer's notification, which needs notification access. */
    private fun askNotificationAccess() {
        if (CallerIdListener.isEnabled(this)) return
        startActivity(
            android.content.Intent(android.provider.Settings.ACTION_NOTIFICATION_LISTENER_DETAIL_SETTINGS)
                .putExtra(
                    android.provider.Settings.EXTRA_NOTIFICATION_LISTENER_COMPONENT_NAME,
                    android.content.ComponentName(this, CallerIdListener::class.java).flattenToString(),
                ),
        )
    }
}
