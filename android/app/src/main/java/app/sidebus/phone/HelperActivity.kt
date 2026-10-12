package app.sidebus.phone

import android.app.Activity
import android.os.Bundle

/**
 * Opened by the Mac over adb when it starts the call helper, or finds it running: takes
 * the helper's secret and starts the call service, which HyperOS keeps from starting on
 * its own at boot. Guarded by android.permission.DUMP in the manifest, which the adb shell
 * holds and no app can, so no app can slip in a secret of its own.
 */
class HelperActivity : Activity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        intent.getStringExtra("secret")
            ?.takeIf { it.matches(Regex("[0-9a-f]{64}")) }
            ?.let { CallBridgeClient(this).setSecret(it) }
        PhoneService.start(this)
        finish()
    }
}
