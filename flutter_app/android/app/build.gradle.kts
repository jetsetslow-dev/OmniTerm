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

    // Release signing, taken from the environment exactly as the Android app's own build does.
    //
    // The Flutter template signs release with the *debug* key so `flutter run --release` works out
    // of the box. That is fine on a workstation and dangerous in a pipeline: the artifact looks
    // shippable, installs, and is signed by a key every Android SDK on earth holds. So a build that
    // declares itself a distribution build must supply real credentials, and one that does not is
    // signed debug *and says so in its own configuration name* rather than quietly passing for the
    // real thing.
    signingConfigs {
        create("release") {
            val keystorePath = System.getenv("KEYSTORE_PATH")
            if (keystorePath != null) {
                storeFile = file(keystorePath)
                storePassword = System.getenv("STORE_PASSWORD")
                    ?: error("STORE_PASSWORD is required when KEYSTORE_PATH is set")
                keyAlias = System.getenv("KEY_ALIAS")
                    ?: error("KEY_ALIAS is required when KEYSTORE_PATH is set")
                keyPassword = System.getenv("KEY_PASSWORD")
                    ?: error("KEY_PASSWORD is required when KEYSTORE_PATH is set")
            }
        }
    }

    buildTypes {
        debug {
            // Installs alongside the Kotlin app rather than replacing it. The shipped app is
            // `com.jetsetslow.omniterm.app` (Play) and `…app.oss` (source-available); a debug build
            // of this port carries a third id so the two can be compared side by side on one
            // device — which is the only way to check parity on real hardware.
            applicationIdSuffix = ".flutter"
            versionNameSuffix = "-flutter"
            manifestPlaceholders["appLabel"] = "OmniTerm Flutter"
        }

        release {
            manifestPlaceholders["appLabel"] = "omniterm"
            // R8 stops on a reference it cannot resolve, and the SMB client brings several that are
            // absent by design. See `proguard-rules.pro` — every rule there says why.
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )

            // `KEYSTORE_PATH` absent means nobody supplied a distribution key, so this is a local
            // or CI verification build: sign it debug so it still installs, and leave the
            // distribution path to fail loudly above rather than silently downgrade.
            signingConfig = if (System.getenv("KEYSTORE_PATH") != null) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
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
