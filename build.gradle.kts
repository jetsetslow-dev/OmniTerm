// Android's own plugin classpath includes bundletool, SDK, and Jetifier libraries. Substitute
// vulnerable versions before Gradle loads those tools, not just in the app's configurations.
//
// The module and versions are deliberately separate strings: the map KEYS are the VULNERABLE
// transitive versions this protection exists to catch, and Dependabot's Gradle parser treats any
// full "group:name:version" literal as a dependency declaration and "bumps" the key — turning the
// substitution into a useless identity mapping (seen in its PRs #37/#38). Keeping the coordinate
// split stops the false positives without ignoring the real dependencies.
buildscript {
  configurations.configureEach {
    resolutionStrategy.dependencySubstitution {
      val patchedModules = listOf(
        Triple("com.google.guava:guava", "30.1.1-jre", "33.6.0-jre"),
        Triple("org.apache.commons:commons-lang3", "3.16.0", "3.19.0"),
        Triple("org.bitbucket.b_c:jose4j", "0.9.5", "0.9.6"),
        Triple("org.bouncycastle:bcprov-jdk18on", "1.79", "1.86"),
        Triple("org.bouncycastle:bcpkix-jdk18on", "1.79", "1.86"),
        Triple("org.bouncycastle:bcutil-jdk18on", "1.79", "1.86"),
        Triple("org.jdom:jdom2", "2.0.6", "2.0.6.1"),
      )
      patchedModules.forEach { (moduleId, vulnerableVersion, patchedVersion) ->
        substitute(module("$moduleId:$vulnerableVersion"))
          .using(module("$moduleId:$patchedVersion"))
          .because("Avoid loading vulnerable transitive build dependencies")
      }
    }
  }
}

// Top-level build file where you can add configuration options common to all sub-projects/modules.
plugins {
  alias(libs.plugins.android.application) apply false
  alias(libs.plugins.kotlin.compose) apply false
  alias(libs.plugins.google.devtools.ksp) apply false
  alias(libs.plugins.roborazzi) apply false
}

val kotlinBaseline = libs.versions.kotlin.get()
val bouncyCastleBaseline = libs.versions.bcprov.get()

// Android's lint, emulator, bundle and test tooling resolves several older transitive libraries
// even though the top-level plugins are current. Keep those build-time parsers and network stacks
// on patched, binary-compatible releases as well as hardening the dependencies packaged in APKs.
allprojects {
  configurations.configureEach {
    val resolvedConfigurationName = name
    resolutionStrategy.dependencySubstitution {
      // Split coordinates for the same reason as the buildscript block above: the keys must stay
      // at the VULNERABLE versions, and Dependabot rewrites full-coordinate literals.
      val patchedModules = listOf(
        Triple("com.google.guava:guava", "30.1.1-jre", "33.6.0-jre"),
        Triple("org.apache.commons:commons-lang3", "3.16.0", "3.19.0"),
        Triple("org.bouncycastle:bcprov-jdk18on", "1.79", bouncyCastleBaseline),
        Triple("org.bouncycastle:bcpkix-jdk18on", "1.79", bouncyCastleBaseline),
        Triple("org.bouncycastle:bcutil-jdk18on", "1.79", bouncyCastleBaseline),
      )
      patchedModules.forEach { (moduleId, vulnerableVersion, patchedVersion) ->
        substitute(module("$moduleId:$vulnerableVersion"))
          .using(module("$moduleId:$patchedVersion"))
          .because("Avoid resolving vulnerable transitive build dependencies")
      }
    }
    resolutionStrategy.eachDependency {
      when {
        resolvedConfigurationName == "kotlinAbiValidationCompatClasspath" &&
          requested.group == "org.jetbrains.kotlin" -> {
          // Kotlin 2.4.0 declares this internal tool classpath as the open range
          // [2.4.0-Beta2, 2.5.0). Every new beta/RC published by JetBrains therefore changes a
          // previously green build and trips strict dependency verification. Keep the ABI helper
          // on the same reviewed Kotlin baseline as the compiler plugin; intentional Kotlin
          // upgrades update both through the version catalog and verification metadata.
          useVersion(kotlinBaseline)
          because("keep ABI validation tooling reproducible and aligned with the Kotlin plugin")
        }
        requested.group == "io.netty" && requested.name.startsWith("netty-") -> {
          useVersion("4.1.135.Final")
          because("align the Netty family to the patched security baseline")
        }
        // Keep the provider and its companion modules on the reviewed catalog release. A literal
        // useVersion pin here silently overrode Dependabot's provider bump in the app graph.
        // 1.86 includes the AES-256/CBC OID correction introduced by the provider-only 1.85.2 patch.
        requested.group == "org.bouncycastle" && requested.name in setOf(
          "bcprov-jdk18on", "bcpkix-jdk18on", "bcutil-jdk18on"
        ) -> {
          useVersion(bouncyCastleBaseline)
          because("align the Bouncy Castle family to the reviewed security baseline")
        }
        requested.group == "com.google.guava" && requested.name == "guava" &&
          requested.version.orEmpty().endsWith("-android") -> {
          useVersion("33.6.0-android")
          because("replace vulnerable Android-flavoured Guava transitives")
        }
        requested.group == "org.apache.commons" && requested.name == "commons-lang3" -> {
          useVersion("3.19.0")
          because("use a release with bounded recursive processing")
        }
        requested.group == "org.apache.httpcomponents" &&
          requested.name in setOf("httpclient", "httpmime") -> {
          useVersion("4.5.14")
          because("align Apache HttpComponents clients to the patched maintenance release")
        }
        requested.group == "org.apache.httpcomponents" && requested.name == "httpcore" -> {
          useVersion("4.4.16")
          because("align Apache HttpComponents core with the patched client family")
        }
      }
    }
  }
}
