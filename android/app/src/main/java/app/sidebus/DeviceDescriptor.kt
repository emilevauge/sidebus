package app.sidebus

import android.content.Context
import android.media.MediaCodecList
import android.os.Build
import android.provider.Settings
import android.view.WindowManager
import app.sidebus.pairing.DeviceIdentity
import app.sidebus.protocol.Codec
import app.sidebus.protocol.Message

/** What the tablet announces to the Mac in DEVICE_INFO. */
object DeviceDescriptor {

    fun deviceInfo(context: Context): Message.DeviceInfo {
        val windowManager = context.getSystemService(WindowManager::class.java)
        val bounds = windowManager.currentWindowMetrics.bounds
        // Always in landscape, whatever the current orientation is.
        val width = maxOf(bounds.width(), bounds.height())
        val height = minOf(bounds.width(), bounds.height())

        return Message.DeviceInfo(
            width = width,
            height = height,
            density = context.resources.displayMetrics.densityDpi,
            codecs = supportedCodecs(),
            name = name(context),
            uuid = DeviceIdentity.uuid(context),
        )
    }

    fun name(context: Context): String =
        Settings.Global.getString(context.contentResolver, Settings.Global.DEVICE_NAME)
            ?: "${Build.MANUFACTURER} ${Build.MODEL}"

    /** Bitmask of the codecs the tablet can decode in hardware. */
    private fun supportedCodecs(): Int {
        var mask = 0
        val list = MediaCodecList(MediaCodecList.REGULAR_CODECS)
        for (info in list.codecInfos) {
            if (info.isEncoder) continue
            if (Build.VERSION.SDK_INT >= 29 && !info.isHardwareAccelerated) continue
            for (type in info.supportedTypes) {
                when (type.lowercase()) {
                    "video/avc" -> mask = mask or Codec.H264
                    "video/hevc" -> mask = mask or Codec.HEVC
                }
            }
        }
        return mask
    }
}
