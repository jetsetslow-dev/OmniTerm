package com.jetsetslow.omniterm

import android.app.Activity
import android.os.Build
import com.google.android.gms.ads.identifier.AdvertisingIdClient
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

/** Build/device facts used by About diagnostics; no host or account data crosses this bridge. */
object DeviceInfoBridge {
    fun register(engine: FlutterEngine, activity: Activity) {
        val executor = Executors.newSingleThreadExecutor()
        MethodChannel(engine.dartExecutor.binaryMessenger, "omniterm/device_info")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "details" -> result.success(
                        mapOf(
                            "device" to "${Build.MANUFACTURER} ${Build.MODEL}",
                            "platform" to "Android ${Build.VERSION.RELEASE} (API ${Build.VERSION.SDK_INT})",
                            "abi" to (Build.SUPPORTED_ABIS.firstOrNull() ?: "unknown"),
                        ),
                    )
                    "advertisingId" -> executor.execute {
                        val id = runCatching {
                            AdvertisingIdClient.getAdvertisingIdInfo(activity.applicationContext).id
                        }.getOrNull() ?: "Unavailable"
                        activity.runOnUiThread { result.success(id) }
                    }
                    else -> result.notImplemented()
                }
            }
    }
}
