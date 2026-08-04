plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.jetsetslow.omniterm"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        // flutter_local_notifications requires the java.time backport on API < 26. The legacy app
        // supports API 24, so desugaring is mandatory rather than optional here.
        isCoreLibraryDesugaringEnabled = true
    }

    defaultConfig {
        applicationId = "com.jetsetslow.omniterm.app"
        // Matches the legacy Android app (app/build.gradle.kts) so the migration does not silently
        // drop support for devices the shipped app already serves.
        minSdk = 24
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName

        // Patrol's instrumentation runner (§11). The app itself is unaffected: this only applies to
        // androidTest builds.
        testInstrumentationRunner = "pl.leancode.patrol.PatrolJUnitRunner"
        testInstrumentationRunnerArguments["clearPackageData"] = "true"
    }

    testOptions {
        execution = "ANDROIDX_TEST_ORCHESTRATOR"
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.5")

    androidTestUtil("androidx.test:orchestrator:1.5.1")

    // SMB2/3 (MIGRATION.md §7.1). Native rather than Dart because the only pub package for SMB pins
    // a pointycastle major dartssh2 cannot coexist with, and is an unmaintained implementation of a
    // large attacker-reachable wire protocol. smbj is the same client the Kotlin app already ships.
    implementation("com.hierynomus:smbj:0.14.0") {
        // smbj declares its own Bouncy Castle artifact; excluded to keep one crypto provider on the
        // classpath rather than two that can shadow each other.
        exclude(group = "org.bouncycastle")
    }
}
