import org.jetbrains.kotlin.gradle.dsl.JvmTarget
import org.jetbrains.kotlin.gradle.plugin.mpp.KotlinNativeTarget

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
    withHostTestBuilder {}.configure {}
    compilerOptions.jvmTarget.set(JvmTarget.JVM_17)
  }

  iosArm64()
  iosSimulatorArm64()

  targets.withType<KotlinNativeTarget>().configureEach {
    binaries.framework {
      baseName = "OmniTermShared"
      isStatic = true
    }
  }

  sourceSets {
    commonMain.dependencies {
      implementation(libs.compose.multiplatform.runtime)
      implementation(libs.compose.multiplatform.foundation)
      implementation(libs.compose.multiplatform.ui)
      // The Compose plugin selects its compatible Material 3 artifact. Its Maven version does not
      // track the Compose Multiplatform plugin version one-for-one.
      implementation(libs.compose.multiplatform.material3)
      implementation(libs.kotlinx.coroutines.core)
      implementation(libs.ktor.client.core)
    }
    androidMain.dependencies {
      implementation(libs.ktor.client.android)
    }
    iosMain.dependencies {
      implementation(libs.ktor.client.darwin)
    }
    commonTest.dependencies {
      implementation(kotlin("test"))
      implementation(libs.kotlinx.coroutines.test)
    }
  }
}
