// Android's own plugin classpath includes bundletool, SDK, and Jetifier libraries. Substitute
// vulnerable versions before Gradle loads those tools, not just in the app's configurations.
buildscript {
  configurations.configureEach {
    resolutionStrategy.dependencySubstitution {
      val patchedModules = mapOf(
        "com.google.guava:guava:30.1.1-jre" to "com.google.guava:guava:33.6.0-jre",
        "org.apache.commons:commons-lang3:3.16.0" to "org.apache.commons:commons-lang3:3.19.0",
        "org.bitbucket.b_c:jose4j:0.9.5" to "org.bitbucket.b_c:jose4j:0.9.6",
        "org.bouncycastle:bcprov-jdk18on:1.79" to "org.bouncycastle:bcprov-jdk18on:1.85",
        "org.bouncycastle:bcpkix-jdk18on:1.79" to "org.bouncycastle:bcpkix-jdk18on:1.85",
        "org.bouncycastle:bcutil-jdk18on:1.79" to "org.bouncycastle:bcutil-jdk18on:1.85",
        "org.jdom:jdom2:2.0.6" to "org.jdom:jdom2:2.0.6.1",
      )
      patchedModules.forEach { (vulnerableCoordinate, patchedCoordinate) ->
        substitute(module(vulnerableCoordinate))
          .using(module(patchedCoordinate))
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

// Android's lint, emulator, bundle and test tooling resolves several older transitive libraries
// even though the top-level plugins are current. Keep those build-time parsers and network stacks
// on patched, binary-compatible releases as well as hardening the dependencies packaged in APKs.
allprojects {
  configurations.configureEach {
    resolutionStrategy.dependencySubstitution {
      val patchedModules = mapOf(
        "com.google.guava:guava:30.1.1-jre" to "com.google.guava:guava:33.6.0-jre",
        "org.apache.commons:commons-lang3:3.16.0" to "org.apache.commons:commons-lang3:3.19.0",
        "org.bouncycastle:bcprov-jdk18on:1.79" to "org.bouncycastle:bcprov-jdk18on:1.85",
        "org.bouncycastle:bcpkix-jdk18on:1.79" to "org.bouncycastle:bcpkix-jdk18on:1.85",
        "org.bouncycastle:bcutil-jdk18on:1.79" to "org.bouncycastle:bcutil-jdk18on:1.85",
      )
      patchedModules.forEach { (vulnerableCoordinate, patchedCoordinate) ->
        substitute(module(vulnerableCoordinate))
          .using(module(patchedCoordinate))
          .because("Avoid resolving vulnerable transitive build dependencies")
      }
    }
    resolutionStrategy.eachDependency {
      when {
        requested.group == "io.netty" && requested.name.startsWith("netty-") -> {
          useVersion("4.1.135.Final")
          because("align the Netty family to the patched security baseline")
        }
        requested.group == "org.bouncycastle" && requested.name in setOf(
          "bcprov-jdk18on", "bcpkix-jdk18on", "bcutil-jdk18on"
        ) -> {
          useVersion("1.85")
          because("align Bouncy Castle runtime and Android build tooling to patched releases")
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
