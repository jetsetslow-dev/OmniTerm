pluginManagement {
    val flutterSdkPath =
        run {
            val properties = java.util.Properties()
            file("local.properties").inputStream().use { properties.load(it) }
            val flutterSdkPath = properties.getProperty("flutter.sdk")
            require(flutterSdkPath != null) { "flutter.sdk not set in local.properties" }
            flutterSdkPath
        }

    includeBuild("$flutterSdkPath/packages/flutter_tools/gradle")

    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

plugins {
    id("dev.flutter.flutter-plugin-loader") version "1.0.0"
    // Keep the port on the same current stable AGP as the Kotlin app. 9.3.1 supports compileSdk 37.
    id("com.android.application") version "9.3.1" apply false
    // Same newest CodeQL-compatible Kotlin as the Kotlin app; 2.4.10 is held by its extractor.
    id("org.jetbrains.kotlin.android") version "2.4.0" apply false
}

include(":app")
