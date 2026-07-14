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
    configurations.configureEach {
        resolutionStrategy.dependencySubstitution {
            val patchedModules = mapOf(
                "com.fasterxml.jackson.core:jackson-core:2.20.1" to "com.fasterxml.jackson.core:jackson-core:2.22.1",
                "com.fasterxml.jackson.core:jackson-databind:2.20.1" to "com.fasterxml.jackson.core:jackson-databind:2.22.1",
                "com.google.guava:guava:30.1.1-jre" to "com.google.guava:guava:33.6.0-jre",
                "org.apache.commons:commons-lang3:3.16.0" to "org.apache.commons:commons-lang3:3.19.0",
                "org.bitbucket.b_c:jose4j:0.9.5" to "org.bitbucket.b_c:jose4j:0.9.6",
                "org.bouncycastle:bcprov-jdk18on:1.79" to "org.bouncycastle:bcprov-jdk18on:1.85",
                "org.bouncycastle:bcpkix-jdk18on:1.79" to "org.bouncycastle:bcpkix-jdk18on:1.85",
                "org.bouncycastle:bcutil-jdk18on:1.79" to "org.bouncycastle:bcutil-jdk18on:1.85",
                "org.codehaus.plexus:plexus-utils:3.6.0" to "org.codehaus.plexus:plexus-utils:3.6.1",
                "org.jdom:jdom2:2.0.6" to "org.jdom:jdom2:2.0.6.1",
            )
            patchedModules.forEach { (vulnerableCoordinate, patchedCoordinate) ->
                substitute(module(vulnerableCoordinate))
                    .using(module(patchedCoordinate))
                    .because("Keep SBOM build tooling on patched dependency versions")
            }
        }
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
