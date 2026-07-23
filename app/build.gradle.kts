plugins {
  alias(libs.plugins.android.application)
  alias(libs.plugins.kotlin.compose)
  alias(libs.plugins.google.devtools.ksp)
  alias(libs.plugins.roborazzi)
}

// Version identity comes from CI (.github/workflows/android-release.yml). VERSION_NAME is the
// release tag without the leading "v"; VERSION_CODE packs it as
//   major*10_000_000 + minor*100_000 + patch*100 + build
// where a bare release owns build slot 99 and a -Suffix takes its trailing digits as the build
// (1.0.0-Beta -> 1, 1.0.0-Beta2 -> 2, 1.0.0 -> 99) — so a Beta chain climbs 1..98 and dropping
// the suffix to finalize is always a strictly higher code. Play's "codes must increase" rule
// thereby reduces to "versions must increase". When VERSION_CODE isn't given explicitly it is
// derived from VERSION_NAME here; local dev builds (no env) get placeholders, never published.
val versionNameValue = System.getenv("VERSION_NAME") ?: "0.0.0-dev"
val packedFromName = Regex("""^(\d+)\.(\d+)\.(\d+)(?:-(.*))?$""").find(versionNameValue)?.let { m ->
  val (major, minor, patch, suffix) = m.destructured
  val build = if (!versionNameValue.contains('-')) 99
  else Regex("""(\d+)$""").find(suffix)?.value?.toIntOrNull()?.coerceIn(1, 98) ?: 1
  major.toInt() * 10_000_000 + minor.toInt() * 100_000 + patch.toInt() * 100 + build
}
val versionCodeValue = System.getenv("VERSION_CODE")?.toIntOrNull()
    ?: packedFromName
    ?: 1

android {
  namespace = "com.jetsetslow.omniterm"
  compileSdk = 36

  defaultConfig {
    applicationId = "com.jetsetslow.omniterm.app"
    minSdk = 24
    targetSdk = 36
    versionCode = versionCodeValue
    versionName = versionNameValue

    testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
  }

  // MigrationTestHelper reads exported Room schemas from the instrumentation APK's assets.
  // Exporting them for KSP is not enough: package the committed schema matrix for every flavor.
  sourceSets {
    getByName("androidTest").assets.directories.add("$projectDir/schemas")
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
  val requestedTasks = gradle.startParameter.taskNames.map { it.substringAfterLast(':').lowercase() }
  val isPlayStoreRelease = requestedTasks.any {
      it.contains("playstorerelease") || it == "assemblerelease" || it == "bundlerelease"
  }
  if (isPlayStoreRelease && (admobAppId == admobTestAppId || admobBannerId == admobTestBannerId)) {
    error("playStore release build with Google's sample AdMob IDs — set ADMOB_APP_ID and ADMOB_BANNER_UNIT_ID (env or gradle property).")
  }

  flavorDimensions += "distribution"
  productFlavors {
    create("openSource") {
      dimension = "distribution"
      applicationIdSuffix = ".oss"
      buildConfigField("boolean", "PLAY_STORE_BUILD", "false")
      buildConfigField("String", "DISTRIBUTION_NAME", "\"Source Available\"")
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

  signingConfigs {
    create("release") {
      val keystorePath = System.getenv("KEYSTORE_PATH")
          ?: if (isPlayStoreRelease) "${rootDir}/jetsetslow-release-key.keystore" else "${rootDir}/debug.keystore"
      storeFile = file(keystorePath)
      storePassword = System.getenv("STORE_PASSWORD")
          ?: if (isPlayStoreRelease) error("STORE_PASSWORD env var is required for Play Store release builds") else "android"
      keyAlias = System.getenv("KEY_ALIAS")
          ?: if (isPlayStoreRelease) error("KEY_ALIAS env var is required for Play Store release builds") else "androiddebugkey"
      keyPassword = System.getenv("KEY_PASSWORD")
          ?: if (isPlayStoreRelease) error("KEY_PASSWORD env var is required for Play Store release builds") else "android"
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
      // AGP 9.1.1 is producing an invalid shrunk-resource archive for AppCompat vector resources
      // in this project ("Zip: invalid file name at entry ..."). Keep R8 code minification on, but
      // disable resource shrinking so release packaging remains deterministic.
      isShrinkResources = false
      proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
      signingConfig = signingConfigs.getByName("release")
    }
    debug {
      signingConfig = signingConfigs.getByName("debugConfig")
    }
  }
  compileOptions {
    sourceCompatibility = JavaVersion.VERSION_17
    targetCompatibility = JavaVersion.VERSION_17
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

val lowResourceBuild = providers.gradleProperty("omniterm.lowResourceBuild")
  .map { it.toBoolean() }
  .getOrElse(false)

tasks.withType<org.gradle.api.tasks.testing.Test>().configureEach {
  if (lowResourceBuild) {
    maxParallelForks = 1
    maxHeapSize = "768m"
    exclude(
      "**/AppResourcesTest.class",
      "**/GreetingScreenshotTest.class",
      "**/PinHashRobolectricTest.class",
      "**/ColdStartRobolectricTest.class",
      "**/TerminalNavigationRobolectricTest.class",
    )
  }
}

dependencies {
  constraints {
    implementation(libs.guava.android) {
      because("Play Ads transitively requests a Guava release with published security advisories")
    }
  }
  implementation(platform(libs.androidx.compose.bom))
  implementation(libs.androidx.activity.compose)
  implementation(libs.androidx.compose.material.icons.core)
  implementation(libs.androidx.compose.material.icons.extended)
  // Maintained drop-in fork of the abandoned com.jcraft:jsch:0.1.55 — same `com.jcraft.jsch`
  // API, but parses modern keys: OpenSSH containers (-----BEGIN OPENSSH PRIVATE KEY-----, the
  // default from recent ssh-keygen) plus ed25519/ecdsa. Also patches the old JSch CVEs.
  implementation(libs.jsch)
  // ed25519/ed448 signing & key parsing. On Android the platform JCA has no EdDSA provider, so
  // JSch selects its `com.jcraft.jsch.bc.*` EdDSA backend, which needs Bouncy Castle's lightweight
  // crypto API on the classpath. Without this, RSA/ECDSA keys authenticate but every modern
  // OpenSSH ed25519 key (the ssh-keygen default) silently fails public-key auth.
  implementation(libs.bcprov)
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
  implementation(libs.androidx.compose.material)
  implementation(libs.androidx.compose.ui)
  implementation(libs.androidx.compose.ui.graphics)
  implementation(libs.androidx.compose.ui.tooling.preview)
  implementation(libs.androidx.core.ktx)
  implementation(libs.androidx.appcompat)
  // Chrome Custom Tabs: terminal links can open in an in-app browser tab (user's default browser
  // engine rendered over our task) instead of switching to the external browser app.
  implementation(libs.androidx.browser)
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
  // Room's migration test runtime pulls kotlinx-serialization-json 1.8.1. Keep its transitive
  // core module aligned in every variant; mixed 1.8.1/1.7.3 binaries fail with AbstractMethodError.
  implementation(platform(libs.kotlinx.serialization.bom))
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
  testImplementation(libs.mockk)
  testImplementation(libs.truth)
  testImplementation(libs.robolectric)
  testImplementation(libs.roborazzi)
  testImplementation(libs.roborazzi.compose)
  testImplementation(libs.roborazzi.junit.rule)
  androidTestImplementation(platform(libs.androidx.compose.bom))
  androidTestImplementation(libs.androidx.compose.ui.test.junit4)
  androidTestImplementation(libs.androidx.room.testing)
  androidTestImplementation(libs.androidx.espresso.core)
  androidTestImplementation(libs.androidx.junit)
  androidTestImplementation(libs.androidx.runner)
  debugImplementation(libs.androidx.compose.ui.test.manifest)
  debugImplementation(libs.androidx.compose.ui.tooling)
  "ksp"(libs.androidx.room.compiler)
  "ksp"(libs.moshi.kotlin.codegen)
}
