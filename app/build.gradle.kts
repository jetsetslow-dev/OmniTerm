plugins {
  alias(libs.plugins.android.application)
  alias(libs.plugins.kotlin.compose)
  alias(libs.plugins.google.devtools.ksp)
  alias(libs.plugins.roborazzi)
}

// Version identity comes from CI (.github/workflows/android-release.yml and android-debug.yml).
// VERSION_NAME is the release tag without the leading "v"; VERSION_CODE packs it as
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
  compileSdk = 37

  defaultConfig {
    applicationId = "com.jetsetslow.omniterm.app"
    minSdk = 24
    targetSdk = 37
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

  // GitHub releases carry the open-source app as one APK per architecture next to a universal APK
  // that works on every phone. The release workflow asks for them (-Pomniterm.abiSplits=true); every
  // other build makes one APK. Each keeps the release's own version code, as the Play bundle does:
  // Play gets only the bundle and serves each phone its part, so per-architecture codes would buy
  // nothing, and equal codes let a phone move between the universal APK and its own either way.
  // scripts/verify-release-apks.py checks the built files.
  splits {
    abi {
      isEnable = providers.gradleProperty("omniterm.abiSplits").map { it.toBoolean() }.getOrElse(false)
      reset()
      include("arm64-v8a", "armeabi-v7a", "x86_64")
      isUniversalApk = true
    }
  }
  // 32-bit x86 is not built. The Go tunnel library has no x86 copy (scripts/build-tunnel.sh), so no
  // other library's x86 copy ships either: an x86 device refuses the install rather than getting an
  // app whose tunnels cannot load.
  packaging { jniLibs { excludes += "lib/x86/**" } }
}

ksp {
  // Export Room schemas so migrations can be written/tested against the committed prior shape.
  arg("room.schemaLocation", "$projectDir/schemas")
}

// The Go tunnel library (tunnel/), built for the three ABIs the app ships (arm64-v8a, armeabi-v7a,
// x86_64) with the repository's pinned Go toolchain and NDK. It is rebuilt only when its sources or the scripts that build it change.
val goTunnelAar = rootProject.layout.projectDirectory.file("tunnel/build/omnitunnel.aar")
val buildGoTunnel by tasks.registering(Exec::class) {
  description = "Builds tunnel/ into an Android library with gomobile."
  val root = rootProject.layout.projectDirectory
  inputs.dir(root.dir("tunnel/omnitunnel"))
  inputs.files(root.file("tunnel/go.mod"), root.file("tunnel/go.sum"), root.file("tunnel/build-tags.txt"), root.file("scripts/build-tunnel.sh"), root.file("scripts/check-tunnel-seam.py"), root.file("scripts/go-toolchain.sh"))
  inputs.property("targets", providers.environmentVariable("OMNITUNNEL_TARGETS").orElse("all"))
  outputs.file(goTunnelAar)
  val sdk = androidComponents.sdkComponents.sdkDirectory
  doFirst { environment("ANDROID_HOME", sdk.get().asFile.path) }
  commandLine(root.file("scripts/build-tunnel.sh").asFile.path, goTunnelAar.asFile.path)
}
// A test build may use another tunnel library instead, given as -Pomniterm.tunnelAar=<file>: the
// Cloudflare Access device suite's, from scripts/build-tunnel.sh --access-fixture. Gradle never
// builds that library, no release may use it, and scripts/check-tunnel-seam.py fails any library
// or app that holds its seam.
val tunnelAarOverride = providers.gradleProperty("omniterm.tunnelAar").orNull
if (tunnelAarOverride != null &&
  gradle.startParameter.taskNames.any { it.substringAfterLast(':').lowercase().let { t -> "release" in t || t == "assemble" || t == "build" || t == "bundle" } }
) {
  error("-Pomniterm.tunnelAar is for test builds only: build a release without it.")
}

val lowResourceBuild = providers.gradleProperty("omniterm.lowResourceBuild")
  .map { it.toBoolean() }
  .getOrElse(false)
val linuxArm64Host =
  System.getProperty("os.name").equals("Linux", ignoreCase = true) &&
    System.getProperty("os.arch").lowercase() in setOf("aarch64", "arm64")

tasks.withType<org.gradle.api.tasks.testing.Test>().configureEach {
  // CI has no test-report artifact on a failed build. Keep the missing class and root cause in
  // its log, rather than reducing every affected test to ClassNotFoundException and a line number.
  testLogging.exceptionFormat = org.gradle.api.tasks.testing.logging.TestExceptionFormat.FULL
  // Forward the fixture-regeneration opt-in into the test JVM. A bare `-Domniterm...` on the Gradle
  // command line only reaches the daemon, so without this the flag is silently ignored and the
  // fixture appears to regenerate while the committed file never changes.
  systemProperty(
    "omniterm.regenerateFixture",
    providers.systemProperty("omniterm.regenerateFixture").getOrElse("false"),
  )
  // Same for SshSignInLiveTest, which signs in to the running test fleet only when asked.
  systemProperty(
    "omniterm.liveSsh",
    providers.systemProperty("omniterm.liveSsh").getOrElse("false"),
  )
  // ToolsPathTextRobolectricTest checks the README's "Tools → …" paths, so editing only the README
  // must rerun the tests rather than leave them up to date.
  inputs.file(rootProject.file("README.md"))
    .withPathSensitivity(PathSensitivity.RELATIVE)
    .withPropertyName("readme")
  if (lowResourceBuild || linuxArm64Host) {
    maxParallelForks = 1
    maxHeapSize = "768m"
  }
  if (lowResourceBuild || linuxArm64Host) {
    // Robolectric 4.16's Android 15 native runtime has no Linux ARM64 binary and fails before a
    // JUnit @Before/assumption can skip the test. Exclude those classes at Gradle discovery time
    // on that host. Critical platform-neutral logic belongs in ordinary JVM tests (for example,
    // TerminalResizeDispatcherTest) so ARM development still exercises it.
    exclude(
      "**/AppResourcesTest.class",
      "**/GreetingScreenshotTest.class",
      "**/PinHashRobolectricTest.class",
      "**/ColdStartRobolectricTest.class",
      "**/TerminalNavigationRobolectricTest.class",
      "**/TmuxResumeLatencyRobolectricTest.class",
      "**/TerminalPasteReceiptRobolectricTest.class",
      "**/TerminalLeavePersistenceRobolectricTest.class",
    )
  }
}

dependencies {
    implementation("androidx.glance:glance-appwidget:1.2.0")
    // Material3 for Glance
    implementation("androidx.glance:glance-material3:1.2.0")
    // Profile Installer for Baseline Profiles
    implementation("androidx.profileinstaller:profileinstaller:1.4.1")
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
  implementation(tunnelAarOverride?.let { files(it) } ?: files(goTunnelAar).builtBy(buildGoTunnel))
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
  // SNMP v2c/v3 polling for Tools → SNMP devices (Apache-2.0, no runtime dependencies). Read-only:
  // OmniTerm sends GET and GETBULK only. Its v3 USM uses the JDK's own MD5/SHA and AES/DES.
  implementation(libs.snmp4j)
  // FIDO2 (CTAP2) over USB and NFC, for SSH keys kept on a security key (sk-ssh-ed25519,
  // sk-ecdsa). Yubico's SDK, which talks to any maker's FIDO2 key, not only YubiKeys.
  implementation(libs.yubikit.android)
  implementation(libs.yubikit.fido)
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
  // The MCP server reads and writes JSON-RPC with its tree API (no compiler plugin), which the
  // shared Kotlin module can use unchanged.
  implementation(libs.kotlinx.serialization.json)
  // The file editor's Markdown preview parses with JetBrains' Kotlin Multiplatform parser
  // (Apache-2.0, depends on kotlin-stdlib only) and draws with the app's own renderer.
  implementation(libs.markdown)
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
