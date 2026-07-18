package com.jetsetslow.omniterm

import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onRoot
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.compose.ui.test.printToString
import androidx.lifecycle.ViewModelProvider
import androidx.test.platform.app.InstrumentationRegistry
import com.jetsetslow.omniterm.data.RemoteCommands
import com.jetsetslow.omniterm.data.ServerEntity
import com.jetsetslow.omniterm.ui.AppViewModel
import com.jetsetslow.omniterm.ui.Screen
import com.jetsetslow.omniterm.ui.parseDockerComposeYaml
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assume.assumeTrue
import org.junit.Rule
import org.junit.Test

/** Physical UI deploy/rollback coverage against only the disposable E2E Raspberry Pi. */
class E2eComposeDeployStressTest {
    @get:Rule
    val composeRule = createAndroidComposeRule<MainActivity>()

    @Test
    fun dockerCustomBuildPodmanAndMalformedRollbackRunThroughBuilderUi() = runBlocking {
        assumeTrue(
            InstrumentationRegistry.getArguments().getString("omniterm_e2e_compose_deploy") == "yes",
        )
        val vm = ViewModelProvider(composeRule.activity)[AppViewModel::class.java]
        composeRule.waitUntil(15_000) { vm.servers.value.any { it.name == HOST } }
        val host = requireNotNull(vm.servers.value.find { it.name == HOST })
        composeRule.runOnUiThread { vm.selectedServerId = host.id }

        val root = "/home/${host.username}/omniterm-e2e/corpus"
        val docker = Fixture("$root/02-custom-build/compose.yml", "omniterm-custom-build", "docker")
        val podman = Fixture("$root/03-podman/compose.yml", "omniterm-podman", "podman")
        val malformed = Fixture("$root/05-malformed/compose.yml", "omniterm-malformed", "docker")

        try {
            // Long-form port mappings are intentionally outside the simplified visual model; the
            // builder must preserve and deploy that valid custom-build fixture through Raw YAML.
            deployThroughUi(vm, host, docker, rawMode = true, expectSuccess = true)
            // The Podman fixture stays in visual mode so both builder modes execute a real deploy.
            deployThroughUi(vm, host, podman, expectSuccess = true)
            deployThroughUi(vm, host, malformed, rawMode = true, expectSuccess = false)
        } finally {
            // Successful fixtures intentionally start real containers; leave the disposable lab as
            // it was so repeated runs do not accumulate ports, networks, or background workloads.
            for (fixture in listOf(docker, podman)) {
                runCatching {
                    vm.executeSshCommand(
                        host,
                        RemoteCommands.dockerComposeAction(
                            fixture.project,
                            fixture.path.substringBeforeLast('/'),
                            fixture.path,
                            "down",
                            runtime = fixture.runtime,
                        ),
                    )
                }
            }
            composeRule.runOnUiThread { vm.clearActiveComposeDraft() }
        }
    }

    private suspend fun deployThroughUi(
        vm: AppViewModel,
        host: ServerEntity,
        fixture: Fixture,
        rawMode: Boolean = false,
        expectSuccess: Boolean,
    ) {
        composeRule.runOnUiThread { vm.selectedServerId = host.id }
        val original = requireNotNull(vm.readComposeFile(fixture.path)) {
            "Could not read ${fixture.path}: ${vm.composeFileReadError}"
        }
        val draft = parseDockerComposeYaml(
            yaml = original,
            projectName = fixture.project,
            workingDir = fixture.path.substringBeforeLast('/'),
            fileName = fixture.path.substringAfterLast('/'),
            composeFilePath = fixture.path,
            composeConfigFiles = fixture.path,
            runtime = fixture.runtime,
        )
        composeRule.runOnUiThread {
            vm.beginComposeDraft(draft)
            vm.activeInfraTab = 1
            vm.navigateTo(Screen.Infra)
        }
        composeRule.waitUntil(30_000) {
            composeRule.onAllNodes(hasText("Compose Builder", substring = false))
                .fetchSemanticsNodes().isNotEmpty()
        }
        if (rawMode) {
            composeRule.onNodeWithText("Raw YAML").performScrollTo().performClick()
        }

        composeRule.onNodeWithText("Validate & Deploy").performScrollTo().performClick()
        composeRule.waitUntil(10_000) {
            composeRule.onAllNodes(hasText("Deploy changes?", substring = false))
                .fetchSemanticsNodes().isNotEmpty()
        }
        composeRule.onNodeWithText("Deploy changes?").fetchSemanticsNode()
        composeRule.onNodeWithText("Deploy").performClick()

        val successOutcome = "Stack deployed"
        val failureOutcome = "Deploy failed — stack left unchanged"
        composeRule.waitUntil(180_000) {
            composeRule.onAllNodes(hasText(successOutcome, substring = false)).fetchSemanticsNodes().isNotEmpty() ||
                composeRule.onAllNodes(hasText(failureOutcome, substring = false)).fetchSemanticsNodes().isNotEmpty()
        }
        val actualSuccess = composeRule.onAllNodes(hasText(successOutcome, substring = false))
            .fetchSemanticsNodes().isNotEmpty()
        assertEquals(
            "unexpected deploy outcome for ${fixture.project}:\n${composeRule.onRoot().printToString(maxDepth = 8)}",
            expectSuccess,
            actualSuccess,
        )

        // A no-edit deploy must never rewrite formatting, and failed validation must restore the
        // previous file byte-for-byte rather than leaving the invalid staging input live.
        assertEquals("compose file changed after ${fixture.project}", original, vm.readComposeFile(fixture.path))
        composeRule.onNodeWithText("Dismiss").performClick()
    }

    private data class Fixture(val path: String, val project: String, val runtime: String)

    private companion object {
        const val HOST = "E2E Foreground Demo"
    }
}
