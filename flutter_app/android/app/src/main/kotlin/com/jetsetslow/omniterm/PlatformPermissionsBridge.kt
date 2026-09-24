package com.jetsetslow.omniterm

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/** Runtime permissions/settings that have no portable Flutter API. */
object PlatformPermissionsBridge {
    private const val CHANNEL = "omniterm/platform_permissions"
    private const val LOCAL_NETWORK = "android.permission.ACCESS_LOCAL_NETWORK"
    private const val REQUEST_LOCAL = 7011
    private const val REQUEST_NOTIFICATIONS = 7012
    private var pending: MethodChannel.Result? = null
    private var pendingCode: Int? = null

    fun register(engine: FlutterEngine, activity: MainActivity) {
        MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "localNetworkRequired" -> result.success(Build.VERSION.SDK_INT >= 37)
                "localNetworkGranted" -> result.success(
                    Build.VERSION.SDK_INT < 37 ||
                        activity.checkSelfPermission(LOCAL_NETWORK) == PackageManager.PERMISSION_GRANTED,
                )
                "notificationGranted" -> result.success(
                    Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU ||
                        activity.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) ==
                        PackageManager.PERMISSION_GRANTED,
                )
                "batteryExempt" -> result.success(
                    activity.getSystemService(PowerManager::class.java)
                        ?.isIgnoringBatteryOptimizations(activity.packageName) == true,
                )
                "requestLocalNetwork" -> request(activity, LOCAL_NETWORK, REQUEST_LOCAL, result)
                "requestNotifications" -> {
                    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) result.success(true)
                    else request(activity, Manifest.permission.POST_NOTIFICATIONS, REQUEST_NOTIFICATIONS, result)
                }
                "openBatterySettings" -> {
                    result.success(open(activity, Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS)))
                }
                "openAppSettings" -> {
                    result.success(
                        open(
                            activity,
                            Intent(
                                Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                                Uri.parse("package:${activity.packageName}"),
                            ),
                        ),
                    )
                }
                else -> result.notImplemented()
            }
        }
    }

    fun onRequestPermissionsResult(requestCode: Int, grantResults: IntArray): Boolean {
        if (requestCode != pendingCode) return false
        pending?.success(grantResults.firstOrNull() == PackageManager.PERMISSION_GRANTED)
        pending = null
        pendingCode = null
        return true
    }

    private fun request(
        activity: MainActivity,
        permission: String,
        code: Int,
        result: MethodChannel.Result,
    ) {
        if (pending != null) {
            result.error("request_in_progress", "Another permission request is already visible", null)
            return
        }
        pending = result
        pendingCode = code
        activity.requestPermissions(arrayOf(permission), code)
    }

    private fun open(context: Context, intent: Intent): Boolean = runCatching {
        context.startActivity(intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        true
    }.getOrDefault(false)
}
