plugins {
  alias(libs.plugins.android.application)
  alias(libs.plugins.kotlin.compose)
  alias(libs.plugins.google.devtools.ksp)
  alias(libs.plugins.roborazzi)
}

// providers.exec is the configuration-cache-safe way to shell out at configuration time
// (a raw ProcessBuilder here makes Gradle 9 refuse to store the configuration cache).
val gitCommitCount = try {
  providers.exec {
    commandLine("git", "rev-list", "--count", "HEAD")
  }.standardOutput.asText.get().trim().toInt()
} catch (e: Exception) {
  8
}

// This repository moved after Play had already accepted versionCode 140. Keep an explicit floor
// so commit-count-based auto-incrementing remains monotonic after the history reset.
val versionCodeFloor = System.getenv("VERSION_CODE_FLOOR")?.toIntOrNull()
    ?: (project.findProperty("VERSION_CODE_FLOOR") as String?)?.toIntOrNull()
    ?: 140
// Play rejects any version code it has ever seen, so rebuilding the same commit (e.g. after a
// manual Console upload) needs a way to claim a fresh code without an empty commit.
val versionCodeOverride = System.getenv("VERSION_CODE")?.toIntOrNull()
val versionCodeValue = versionCodeOverride ?: (versionCodeFloor + gitCommitCount)
val versionMajor = System.getenv("VERSION_MAJOR")?.toIntOrNull() ?: 0
val versionMinor = System.getenv("VERSION_MINOR")?.toIntOrNull() ?: 9

android {
  namespace = "com.jetsetslow.omniterm"
  compileSdk = 36

  defaultConfig {
    applicationId = "com.jetsetslow.omniterm.app"
    minSdk = 24
    targetSdk = 36
    versionCode = versionCodeValue
    versionName = "$versionMajor.$versionMinor.$versionCodeValue"

    testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
  }

  // Real AdMob IDs are injected from CI secrets (env vars) or local gradle properties; local and
  // debug builds fall back to Google's official sample IDs, which only ever serve test ads.
  val admobTestAppId = "ca-app-pub-3940256099942544~3347511713"
  val admobTestBannerId = "ca-app-pub-3940256099942544/6300978111"
  val admobAppId = System.getenv("ADMOB_APP_ID")
      ?: (project.findProperty("ADMOB_APP_ID") as String?) ?: admobTestAppId
  val admobBannerId = System.getenv("ADMOB_BANNER_UNIT_ID")
      ?: (project.findProperty("ADMOB_BANNER_UNIT_ID") as String?) ?: admobTestBannerId
  // Optional comma-separated list of AdMob test-device IDs (the hashed IDs the SDK logs on first
  // ad request). Registering a tester's device makes Google serve test ads on the internal track,
  // where a brand-new real unit otherwise returns "no fill". Empty by default — production serves
  // real ads to everyone. Read it from the device's logcat ("Use ... to get test ads on this
  // device") and set ADMOB_TEST_DEVICE_IDS to verify the placement works.
  val admobTestDeviceIds = System.getenv("ADMOB_TEST_DEVICE_IDS")
      ?: (project.findProperty("ADMOB_TEST_DEVICE_IDS") as String?) ?: ""
  val isPlayStoreRelease = gradle.startParameter.taskNames.any { it.contains("playStoreRelease", ignoreCase = true) }
  if (isPlayStoreRelease && (admobAppId == admobTestAppId || admobBannerId == admobTestBannerId)) {
    error("playStore release build with Google's sample AdMob IDs — set ADMOB_APP_ID and ADMOB_BANNER_UNIT_ID (env or gradle property).")
  }

  flavorDimensions += "distribution"
  productFlavors {
    create("openSource") {
      dimension = "distribution"
      applicationIdSuffix = ".oss"
      buildConfigField("boolean", "PLAY_STORE_BUILD", "false")
      buildConfigField("String", "DISTRIBUTION_NAME", "\"Open Source\"")
      // The ads SDK isn't bundled here, but the manifest merger still resolves placeholders.
      manifestPlaceholders["admobAppId"] = admobTestAppId
    }
    create("playStore") {
      dimension = "distribution"
      buildConfigField("boolean", "PLAY_STORE_BUILD", "true")
      buildConfigField("String", "DISTRIBUTION_NAME", "\"Play Store\"")
      manifestPlaceholders["admobAppId"] = admobAppId
      buildConfigField("String", "ADMOB_BANNER_UNIT_ID", "\"$admobBannerId\"")
      buildConfigField("String", "ADMOB_TEST_DEVICE_IDS", "\"$admobTestDeviceIds\"")
    }
  }

  val isReleaseBuild = gradle.startParameter.taskNames.any { it.contains("release", ignoreCase = true) }
  signingConfigs {
    create("release") {
      val keystorePath = System.getenv("KEYSTORE_PATH") ?: "${rootDir}/jetsetslow-release-key.keystore"
      storeFile = file(keystorePath)
      storePassword = System.getenv("STORE_PASSWORD")
          ?: if (isReleaseBuild) error("STORE_PASSWORD env var is required for release builds") else "unset"
      keyAlias = System.getenv("KEY_ALIAS")
          ?: if (isReleaseBuild) error("KEY_ALIAS env var is required for release builds") else "unset"
      keyPassword = System.getenv("KEY_PASSWORD")
          ?: if (isReleaseBuild) error("KEY_PASSWORD env var is required for release builds") else "unset"
    }
    create("debugConfig") {
      storeFile = file("${rootDir}/debug.keystore")
      storePassword = "android"
      keyAlias = "androiddebugkey"
      keyPassword = "android"
    }
  }

  buildTypes {
    release {
      isCrunchPngs = false
      isMinifyEnabled = true
      isShrinkResources = true
      proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
      signingConfig = signingConfigs.getByName("release")
    }
    debug {
      signingConfig = signingConfigs.getByName("debugConfig")
    }
  }
  compileOptions {
    sourceCompatibility = JavaVersion.VERSION_11
    targetCompatibility = JavaVersion.VERSION_11
  }
  buildFeatures {
    compose = true
    buildConfig = true
  }
  lint {
    disable += "NewerVersionAvailable"
    disable += "GradleDependency"
  }
  testOptions { unitTests { isIncludeAndroidResources = true } }
}

ksp {
  // Export Room schemas so migrations can be written/tested against the committed prior shape.
  arg("room.schemaLocation", "$projectDir/schemas")
}

tasks.withType<org.gradle.api.tasks.testing.Test>().configureEach {
  maxParallelForks = 1
  maxHeapSize = "768m"
  val isLinuxArm64 = System.getProperty("os.name").equals("Linux", ignoreCase = true) &&
      System.getProperty("os.arch").equals("aarch64", ignoreCase = true)
  if (isLinuxArm64) {
    exclude("**/ExampleRobolectricTest.class", "**/GreetingScreenshotTest.class", "**/PinHashRobolectricTest.class", "**/ColdStartRobolectricTest.class")
  }
}

tasks.register("rpiDebug") {
  group = "verification"
  description = "Low-resource debug build for Raspberry Pi and other small machines."
  dependsOn("assembleOpenSourceDebug")
}

tasks.register("rpiTest") {
  group = "verification"
  description = "Low-resource unit test run for the open-source debug variant."
  dependsOn("testOpenSourceDebugUnitTest")
}

tasks.register("rpiCheck") {
  group = "verification"
  description = "Low-resource build and unit test run for the open-source debug variant."
  dependsOn("rpiDebug", "rpiTest")
}

dependencies {
  implementation(platform(libs.androidx.compose.bom))
  implementation(libs.androidx.activity.compose)
  implementation(libs.androidx.compose.material.icons.core)
  implementation(libs.androidx.compose.material.icons.extended)
  // Maintained drop-in fork of the abandoned com.jcraft:jsch:0.1.55 — same `com.jcraft.jsch`
  // API, but parses modern keys: OpenSSH containers (-----BEGIN OPENSSH PRIVATE KEY-----, the
  // default from recent ssh-keygen) plus ed25519/ecdsa. Also patches the old JSch CVEs.
  implementation("com.github.mwiede:jsch:0.2.18")
  // ed25519/ed448 signing & key parsing. On Android the platform JCA has no EdDSA provider, so
  // JSch selects its `com.jcraft.jsch.bc.*` EdDSA backend, which needs Bouncy Castle's lightweight
  // crypto API on the classpath. Without this, RSA/ECDSA keys authenticate but every modern
  // OpenSSH ed25519 key (the ssh-keygen default) silently fails public-key auth.
  implementation("org.bouncycastle:bcprov-jdk18on:1.78.1")
  // SMB2/3 client for the Shares browser (network_shares). Pure-JVM, Android-safe; its bcprov
  // needs are satisfied by the pinned bcprov-jdk18on above.
  implementation(libs.smbjrpc) {
    // smbj-rpc's 2018-era POM declares four runtime deps its bytecode never references (verified:
    // zero class-file refs to guava/commons-io/commons-lang3 packages). Left in, bcprov-jdk15on
    // duplicate-classes against the pinned bcprov-jdk18on and guava's ListenableFuture collides
    // with androidx's listenablefuture — both fail checkReleaseDuplicateClasses. It really only
    // needs smbj (above) and slf4j-api, both already on the classpath.
    exclude(group = "org.bouncycastle")
    exclude(group = "com.google.guava")
    exclude(group = "commons-io")
    exclude(group = "org.apache.commons", module = "commons-lang3")
  }
  implementation(libs.smbj) {
    // smbj declares its own Bouncy Castle artifact; the same packages already ship via the pinned
    // bcprov-jdk18on above, and two BC jars on the classpath fail the build with duplicate classes.
    exclude(group = "org.bouncycastle")
  }
  // FTP client for the Shares browser. WebDAV rides on the existing OkHttp dependency.
  implementation(libs.commons.net)
  implementation(libs.androidx.compose.material3)
  implementation("androidx.compose.material:material")
  implementation(libs.androidx.compose.ui)
  implementation(libs.androidx.compose.ui.graphics)
  implementation(libs.androidx.compose.ui.tooling.preview)
  implementation(libs.androidx.core.ktx)
  implementation(libs.androidx.appcompat)
  // implementation(libs.androidx.datastore.preferences)
  implementation(libs.androidx.lifecycle.runtime.compose)
  implementation(libs.androidx.lifecycle.runtime.ktx)
  implementation(libs.androidx.lifecycle.viewmodel.compose)
  implementation(libs.androidx.room.ktx)
  implementation(libs.androidx.room.runtime)
  implementation(libs.androidx.biometric)
  implementation(libs.converter.moshi)
  implementation(libs.kotlinx.coroutines.android)
  implementation(libs.kotlinx.coroutines.core)
  implementation(libs.logging.interceptor)
  implementation(libs.moshi.kotlin)
  implementation(libs.okhttp)
  implementation(libs.retrofit)
  "playStoreImplementation"(libs.billing)
  // Google Mobile Ads (AdMob) — playStore flavor only, so the openSource build carries no
  // proprietary ad SDK. The banner is rendered via FlavorAdBanner (a no-op in openSource).
  "playStoreImplementation"(libs.play.services.ads)
  // User Messaging Platform — collects GDPR/EU consent before ads are requested (required by
  // Google's EU User Consent Policy for EEA/UK users). playStore flavor only.
  "playStoreImplementation"(libs.user.messaging.platform)
  // Play In-App Review — the rating nudge after a few successful SSH sessions. playStore flavor
  // only; the openSource FlavorReview is a no-op.
  "playStoreImplementation"(libs.play.review)
  testImplementation(libs.androidx.compose.ui.test.junit4)
  testImplementation(libs.androidx.core)
  testImplementation(libs.androidx.junit)
  testImplementation(libs.junit)
  testImplementation(libs.kotlinx.coroutines.test)
  testImplementation(libs.robolectric)
  testImplementation(libs.roborazzi)
  testImplementation(libs.roborazzi.compose)
  testImplementation(libs.roborazzi.junit.rule)
  androidTestImplementation(platform(libs.androidx.compose.bom))
  androidTestImplementation(libs.androidx.compose.ui.test.junit4)
  androidTestImplementation(libs.androidx.espresso.core)
  androidTestImplementation(libs.androidx.junit)
  androidTestImplementation(libs.androidx.runner)
  debugImplementation(libs.androidx.compose.ui.test.manifest)
  debugImplementation(libs.androidx.compose.ui.tooling)
  "ksp"(libs.androidx.room.compiler)
  "ksp"(libs.moshi.kotlin.codegen)
}
