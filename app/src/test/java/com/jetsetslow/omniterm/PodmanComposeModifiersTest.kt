package com.jetsetslow.omniterm

import com.google.common.truth.Truth.assertThat
import com.jetsetslow.omniterm.ui.ComposeServiceDraft
import com.jetsetslow.omniterm.ui.ComposeStackDraft
import com.jetsetslow.omniterm.ui.generateDockerComposeYaml
import com.jetsetslow.omniterm.ui.parseDockerComposeYaml
import com.jetsetslow.omniterm.ui.renderComposeYaml
import com.jetsetslow.omniterm.ui.validateComposeDraft
import org.junit.Test

class PodmanComposeModifiersTest {
    @Test
    fun newPodmanStackEmitsKeepIdAndCustomPodGrouping() {
        val draft = ComposeStackDraft(
            projectName = "edge",
            runtime = "podman",
            podmanPodEnabled = true,
            podmanPodName = "edge-pod",
            services = mutableListOf(
                ComposeServiceDraft(serviceName = "api", image = "api:latest", usernsMode = "keep-id"),
                ComposeServiceDraft(serviceName = "db", image = "postgres:17", usernsMode = "keep-id"),
            ),
        )

        val yaml = generateDockerComposeYaml(draft)

        assertThat(yaml).contains("x-podman:\n  in_pod: edge-pod")
        assertThat(Regex("""(?m)^\s+userns_mode: keep-id$""").findAll(yaml).count()).isEqualTo(2)
        val reparsed = parseDockerComposeYaml(yaml, "edge", runtime = "podman")
        assertThat(reparsed.podmanPodEnabled).isTrue()
        assertThat(reparsed.podmanPodName).isEqualTo("edge-pod")
        assertThat(reparsed.services.map { it.usernsMode }).containsExactly("keep-id", "keep-id")
    }

    @Test
    fun disablingProviderDefaultPodAddsExplicitFalseWithoutDamagingExistingYaml() {
        val original = """
            # keep this header comment
            services:
              web:
                image: nginx:stable
                labels:
                  - "custom=preserved"
        """.trimIndent()
        val baseline = parseDockerComposeYaml(original, "site", runtime = "podman")
        assertThat(baseline.podmanPodEnabled).isTrue()

        val rendered = renderComposeYaml(
            baseline.copy(podmanPodEnabled = false, podmanPodName = ""),
            baseline,
        )

        assertThat(rendered).contains("x-podman:\n  in_pod: false")
        assertThat(rendered).contains("# keep this header comment")
        assertThat(rendered).contains("- \"custom=preserved\"")
        val reparsed = parseDockerComposeYaml(rendered, "site", runtime = "podman")
        assertThat(reparsed.podmanPodEnabled).isFalse()
    }

    @Test
    fun dockerGenerationDoesNotLeakPodmanKeepIdOrPodExtension() {
        val draft = ComposeStackDraft(
            runtime = "docker",
            podmanPodEnabled = true,
            podmanPodName = "remembered-pod",
            services = mutableListOf(
                ComposeServiceDraft(serviceName = "web", image = "nginx", usernsMode = "keep-id"),
            ),
        )

        val yaml = generateDockerComposeYaml(draft)

        assertThat(yaml).doesNotContain("x-podman")
        assertThat(yaml).doesNotContain("userns_mode: keep-id")
        // The visual draft keeps the modifier so switching back to Podman does not lose the edit.
        assertThat(draft.services.single().usernsMode).isEqualTo("keep-id")
        assertThat(draft.podmanPodName).isEqualTo("remembered-pod")
    }

    @Test
    fun invalidCustomPodNameIsBlockedBeforeDeployment() {
        val draft = ComposeStackDraft(
            runtime = "podman",
            podmanPodEnabled = true,
            podmanPodName = "bad pod; rm -rf",
            services = mutableListOf(ComposeServiceDraft(serviceName = "web", image = "nginx")),
        )

        assertThat(validateComposeDraft(draft))
            .contains("Pod name has invalid characters. Use letters, numbers, dots, dashes, or underscores.")
    }
}
