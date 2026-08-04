package com.jetsetslow.omniterm

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // Lets the Dart SecretStore read credentials the Kotlin app wrote (MIGRATION.md §7.10).
        LegacySecretBridge.register(flutterEngine)
        // Lets Dart apply FLAG_SECURE; a window flag has no Flutter-side equivalent.
        ScreenSecurityBridge.register(flutterEngine, this)
        // SMB2/3 over smbj (MIGRATION.md §7.1): native rather than Dart, because the only pub
        // package pins a pointycastle major dartssh2 cannot coexist with.
        SmbBridge.register(flutterEngine)
        // Keeps the process — and with it the Dart isolate's SSH sessions — alive in the background.
        SessionServiceBridge.register(flutterEngine, this)
    }
}
