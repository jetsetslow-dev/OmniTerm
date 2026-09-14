package com.jetsetslow.omniterm

import android.content.Context
import android.content.Intent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    /**
     * Reuses the process-wide engine instead of creating one per Activity.
     *
     * The default lifecycle destroys the engine in `onDestroy`, so every Activity recreation killed
     * the Dart isolate that owns the SSH sessions. The foreground service kept the *process* alive;
     * nothing kept the sessions alive. See [RetainedFlutterEngine] for which recreations this app
     * actually sees — the manifest's `configChanges` list means rotation and theme changes are not
     * among them. Returning an engine here makes the embedding treat it as host-owned, so it is
     * not destroyed with this Activity and its entrypoint is not re-run while the isolate is
     * already executing. `configureFlutterEngine` still runs on every attach, which is what
     * re-points the Activity-scoped bridges below at the live Activity.
     */
    override fun provideFlutterEngine(context: Context): FlutterEngine =
        RetainedFlutterEngine.obtain(context)

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // Lets the Dart SecretStore read credentials the Kotlin app wrote during in-place upgrade.
        LegacySecretBridge.register(flutterEngine)
        // Lets Dart apply FLAG_SECURE; a window flag has no Flutter-side equivalent.
        ScreenSecurityBridge.register(flutterEngine, this)
        // SMB2/3 over smbj: native rather than Dart, because the only pub
        // package pins a pointycastle major dartssh2 cannot coexist with.
        SmbBridge.register(flutterEngine)
        // Keeps the process — and with it the Dart isolate's SSH sessions — alive in the background.
        SessionServiceBridge.register(flutterEngine, this)
        // Keeps user-started transfers and other long operations scheduled after app switching.
        LongOperationBridge.register(flutterEngine, this)
        BatterySaverNotificationBridge.register(flutterEngine, this)
        // Launcher/widget/notification entry points must be consumed once and then held behind the
        // Dart app-lock gate. Keeping this at the Activity boundary also handles warm singleTop
        // launches, which do not recreate the Flutter engine.
        ExternalLaunchBridge.register(flutterEngine, this)
        ShortcutBridge.register(flutterEngine, this)
        PlatformPermissionsBridge.register(flutterEngine, this)
        DeviceInfoBridge.register(flutterEngine, this)
        SensitiveClipboardBridge.register(flutterEngine, this)
        CustomTabsBridge.register(flutterEngine, this)
        // Explicit exit. With the engine retained, finishing the Activity no longer ends the
        // isolate, so "Terminate & Exit" has to ask for that directly.
        AppExitBridge.register(flutterEngine, this)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        ExternalLaunchBridge.onNewIntent(intent)
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        PlatformPermissionsBridge.onRequestPermissionsResult(requestCode, grantResults)
    }
}
