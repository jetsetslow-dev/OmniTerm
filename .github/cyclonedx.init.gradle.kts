import org.cyclonedx.gradle.CyclonedxAggregateTask
import org.cyclonedx.gradle.CyclonedxDirectTask
import org.cyclonedx.gradle.CyclonedxPlugin
import org.cyclonedx.model.Component

initscript {
    repositories {
        gradlePluginPortal()
    }
    dependencies {
        classpath("org.cyclonedx.bom:org.cyclonedx.bom.gradle.plugin:3.2.4")
    }
}

rootProject {
    apply<CyclonedxPlugin>()

    val sbomConfiguration = System.getenv("SBOM_CONFIGURATION") ?: "playStoreReleaseRuntimeClasspath"
    val sbomComponentName = System.getenv("SBOM_COMPONENT_NAME") ?: "OmniTerm Play Store"

    allprojects {
        tasks.withType<CyclonedxDirectTask>().configureEach {
            if (project.path == ":app") {
                // This is the dependency graph embedded in the signed Play release. Exclude
                // debug, source-available-only, build-tool, and test configurations.
                includeConfigs.set(listOf(sbomConfiguration))
                projectType.set(Component.Type.APPLICATION)
                componentName.set(sbomComponentName)
                componentVersion.set(System.getenv("RELEASE_LABEL") ?: "unversioned")
                includeLicenseText.set(false)
                includeBuildEnvironment.set(false)
                xmlOutput.unsetConvention()
            } else {
                enabled = false
            }
        }
    }

    tasks.withType<CyclonedxAggregateTask>().configureEach {
        projectType.set(Component.Type.APPLICATION)
        componentName.set(sbomComponentName)
        componentVersion.set(System.getenv("RELEASE_LABEL") ?: "unversioned")
        xmlOutput.unsetConvention()
    }
}
