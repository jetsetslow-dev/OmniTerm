pluginManagement {
  repositories {
    google {
      content {
        includeGroupByRegex("com\\.android.*")
        includeGroupByRegex("com\\.google.*")
        includeGroupByRegex("androidx.*")
      }
    }
    mavenCentral()
    gradlePluginPortal()
  }
}

plugins {
  id("com.gradle.develocity") version "4.4.2"
  id("org.gradle.toolchains.foojay-resolver-convention") version "1.0.0"
}

// Publish a Build Scan only for the deliberately selected CI Gradle invocation in each job.
// Local builds remain private by default, and foreground upload ensures an ephemeral Actions
// runner cannot exit before the scan URL is printed.
val isCiBuild = !System.getenv("CI").isNullOrBlank()
val publishSelectedCiBuildScan = isCiBuild && System.getProperty("omniterm.publishScan") == "true"

develocity {
  buildScan {
    termsOfUseUrl.set("https://gradle.com/help/legal-terms-of-use")
    termsOfUseAgree.set("yes")
    // Keep the predicate non-capturing so Gradle's configuration cache never tries to serialize
    // the settings script object itself. Publish one selected successful build per job, plus any
    // failed CI build so its diagnostics are never lost.
    publishing.onlyIf {
      !System.getenv("CI").isNullOrBlank() &&
        (System.getProperty("omniterm.publishScan") == "true" || it.buildResult.failures.isNotEmpty())
    }
    uploadInBackground.set(false)
    if (isCiBuild) {
      tag("CI")
      if (publishSelectedCiBuildScan) tag("Selected")
      System.getenv("GITHUB_WORKFLOW")?.let { value("GitHub workflow", it) }
      val repository = System.getenv("GITHUB_REPOSITORY")
      val runId = System.getenv("GITHUB_RUN_ID")
      if (!repository.isNullOrBlank() && !runId.isNullOrBlank()) {
        link("GitHub Actions run", "https://github.com/$repository/actions/runs/$runId")
      }
    }
  }
}

dependencyResolutionManagement {
  repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
  repositories {
    google()
    mavenCentral()
  }
}

rootProject.name = "My Application"

include(":app")
