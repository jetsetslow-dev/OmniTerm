package com.jetsetslow.omniterm

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // Lets the Dart SecretStore read credentials the Kotlin app wrote (MIGRATION.md §7.10).
        LegacySecretBridge.register(flutterEngine)
    }
}
