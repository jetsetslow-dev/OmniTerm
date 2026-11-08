import org.jetbrains.kotlin.gradle.dsl.JvmTarget
import org.jetbrains.kotlin.gradle.plugin.KotlinPlatformType
import org.jetbrains.kotlin.gradle.plugin.mpp.KotlinNativeTarget

// Code shared by the Android and iOS apps. commonMain is pure Kotlin: no android.*, no java.*, so
// the same logic and its tests run on both. The Android app depends on this module; the iOS app
// links it as the OmniTermShared framework.
plugins {
  alias(libs.plugins.kotlin.multiplatform)
  alias(libs.plugins.android.kotlin.multiplatform.library)
  alias(libs.plugins.jetbrains.compose)
  alias(libs.plugins.kotlin.compose)
}

kotlin {
  android {
    namespace = "com.jetsetslow.omniterm.shared"
    compileSdk = 37
    minSdk = 24
    // commonTest also runs on the JVM, beside the app's own unit tests.
    withHostTestBuilder {}.configure {}
    compilerOptions.jvmTarget.set(JvmTarget.JVM_17)
  }

  iosArm64()
  iosSimulatorArm64()

  // A dynamic framework: the app embeds it once, and its hosted XCTest bundle links that same copy
  // instead of carrying a second Kotlin runtime.
  targets.withType<KotlinNativeTarget>().configureEach {
    binaries.framework {
      baseName = "OmniTermShared"
    }
  }

  sourceSets {
    // Compose Multiplatform is the iOS app's UI for now. Android keeps its Jetpack Compose BOM
    // until screens move to commonMain, so the shipped app's dependencies do not change.
    iosMain.dependencies {
      implementation(libs.compose.multiplatform.runtime)
      implementation(libs.compose.multiplatform.foundation)
      implementation(libs.compose.multiplatform.ui)
    }
    commonTest.dependencies {
      implementation(kotlin("test"))
    }
  }
}

// Only the iOS code is Compose for now, so only it gets the Compose compiler: the Android side of
// this module stays plain Kotlin, with no Compose runtime on its classpath.
composeCompiler {
  targetKotlinPlatforms.set(setOf(KotlinPlatformType.native))
}
