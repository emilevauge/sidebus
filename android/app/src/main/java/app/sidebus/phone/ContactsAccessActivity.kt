package app.sidebus.phone

import android.Manifest
import android.app.Activity
import android.os.Bundle

/**
 * Asks for the contacts permission and closes. The Mac opens it over adb when
 * [ContactsProvider] reports the permission missing; nothing in the app links to it.
 */
class ContactsAccessActivity : Activity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        requestPermissions(arrayOf(Manifest.permission.READ_CONTACTS), 0)
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        finish()
    }
}
