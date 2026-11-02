package com.jetsetslow.omniterm.data.serial

import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.hardware.usb.UsbDevice
import android.hardware.usb.UsbManager
import android.os.Build
import androidx.core.content.IntentCompat
import java.util.concurrent.ConcurrentHashMap

/**
 * Takes Android's answer when OmniTerm asks to use a USB serial adapter. Not exported: only the
 * PendingIntent OmniTerm hands the system reaches it, and that intent names this class.
 */
class UsbPermissionReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val device = IntentCompat.getParcelableExtra(intent, UsbManager.EXTRA_DEVICE, UsbDevice::class.java) ?: return
        val granted = intent.getBooleanExtra(UsbManager.EXTRA_PERMISSION_GRANTED, false)
        waiting.remove(device.deviceName)?.invoke(granted)
    }

    companion object {
        // One answer awaited per device; asking again replaces the earlier wait.
        private val waiting = ConcurrentHashMap<String, (Boolean) -> Unit>()

        /** Asks Android for [device]; [onResult] gets the answer on the main thread. */
        fun request(context: Context, manager: UsbManager, device: UsbDevice, onResult: (Boolean) -> Unit) {
            waiting[device.deviceName] = onResult
            // Mutable so the system can add the device and the answer; explicit, so only this receiver gets it.
            val intent = Intent(context, UsbPermissionReceiver::class.java)
            // Before Android 12 every PendingIntent is mutable and the flag does not exist.
            val mutable = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) PendingIntent.FLAG_MUTABLE else 0
            val pending = PendingIntent.getBroadcast(context, device.deviceId, intent, mutable or PendingIntent.FLAG_UPDATE_CURRENT)
            manager.requestPermission(device, pending)
        }
    }
}
