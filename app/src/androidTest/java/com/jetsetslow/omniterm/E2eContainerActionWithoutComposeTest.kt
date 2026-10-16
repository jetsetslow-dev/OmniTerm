package com.jetsetslow.omniterm

import androidx.compose.ui.test.hasAnyAncestor
import androidx.compose.ui.test.hasContentDescription
import androidx.compose.ui.test.hasTestTag
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.lifecycle.ViewModelProvider
import androidx.test.platform.app.InstrumentationRegistry
import com.jetsetslow.omniterm.data.RemoteCommands
import com.jetsetslow.omniterm.ui.AppViewModel
import com.jetsetslow.omniterm.ui.Screen
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Rule
import org.junit.Test
import java.util.Base64

/** Opt-in, disposable repository Docker/Podman fixtures only; no personal-host fallback. */
class E2eContainerActionWithoutComposeTest {
    @get:Rule val composeRule = createAndroidComposeRule<MainActivity>()

    @Test fun containerActionsKeepWorkingAfterTheirComposeFileIsDeleted() = runBlocking {
        val args = InstrumentationRegistry.getArguments()
        assumeTrue(args.getString("omniterm_e2e_container_actions") == "yes")
        val runtime = requireNotNull(args.getString("omniterm_container_runtime"))
        require(runtime in listOf("docker", "podman"))
        require(args.getString("host") in listOf("127.0.0.1", "10.0.2.2")) { "Repository fixture endpoint required" }
        require(args.getString("port") == if (runtime == "docker") "2205" else "2206")
        val model = ViewModelProvider(composeRule.activity)[AppViewModel::class.java]
        await { model.servers.value.any { it.name == "E2E Foreground Demo" } }
        val host = model.servers.value.single { it.name == "E2E Foreground Demo" }
        composeRule.runOnUiThread { model.selectedServerId = host.id }
        val project = "omniterm-fileless-device-$runtime"
        val dir = "/home/${host.username}/omniterm-e2e/fileless-device-$runtime"
        val path = "$dir/compose.yml"
        val yaml = """
            services:
              worker:
                image: alpine:3.22
                command: ["sh", "-c", "printf 'fileless-container-ready\\n'; sleep 600"]
        """.trimIndent() + "\n"
        var ids = emptyList<String>()
        try {
            val output = model.executeSshCommand(host, RemoteCommands.composeDeploy(path, project,
                Base64.getEncoder().encodeToString(yaml.toByteArray()), runtime = runtime))
            assertTrue("Fixture deploy failed: $output", output.contains("OMNITERM_DEPLOY_OK"))
            model.executeSshCommand(host, RemoteCommands.dockerComposeAction(project, dir, path, "scale", service = "worker", replicas = 2, runtime = runtime))
            refresh(model)
            ids = model.dockerContainers.filter { it.group == project && it.runtime == runtime }.map { it.id }
            assertEquals("Fixture must have two independent replicas", 2, ids.size)
            model.executeSshCommand(host, "rm -f ${RemoteCommands.shellQuote(path)}")
            composeRule.runOnUiThread { model.dockerStackServiceAction(project, dir, path, "worker", "serviceStop", runtime = runtime) }
            await { !model.actionStreamRunning && !model.dockerLoading }
            refresh(model)
            assertEquals("Stop must use container IDs after Compose deletion: ${model.actionStreamOutput}",
                2, model.dockerContainers.count { it.id in ids && it.runtime == runtime && it.status == "exited" })
            for (id in ids) model.executeSshCommand(host, RemoteCommands.dockerAction(id, "start", runtime))
            refresh(model)
            composeRule.runOnUiThread { model.navigateTo(Screen.Infra); model.activeInfraTab = 0 }
            composeRule.waitForIdle()
            composeRule.onNode(hasContentDescription("Expand containers") and hasAnyAncestor(hasTestTag("infra.stack.$runtime.$project")))
                .performScrollTo().performClick()
            val target = ids.first()
            val sibling = ids.last()
            // The isolated Podman fixture intentionally runs without cgroups, so it cannot
            // pause processes. Keep stop/start/restart/remove mandatory on both runtimes.
            val actions = (if (runtime == "docker") listOf("pause", "unpause") else emptyList()) +
                listOf("stop", "start", "restart", "remove")
            for (action in actions) {
                composeRule.onNodeWithTag("infra.container.$runtime.$target.$action").performScrollTo().performClick()
                composeRule.onNodeWithText("${action.replaceFirstChar { it.uppercase() }} ${model.dockerContainers.first { it.id == target && it.runtime == runtime }.name}?")
                    .assertExists()
                composeRule.onNode(hasText(action.replaceFirstChar { it.uppercase() }) and hasAnyAncestor(hasTestTag("infra.container.confirm"))).performClick()
                await { !model.actionStreamRunning && !model.dockerLoading }
                refresh(model)
                assertEquals("Sibling replica changed after $action", "running",
                    model.dockerContainers.single { it.id == sibling && it.runtime == runtime }.status)
                if (action == "remove") assertTrue(model.dockerContainers.none { it.id == target && it.runtime == runtime })
                else assertEquals(when(action) { "pause" -> "paused"; "stop" -> "exited"; else -> "running" },
                    model.dockerContainers.single { it.id == target && it.runtime == runtime }.status)
                composeRule.runOnUiThread { model.closeActionStream() }
                composeRule.waitForIdle()
            }
            composeRule.runOnUiThread { model.dockerStackAction(project, dir, path, "down", runtime = runtime) }
            await { !model.actionStreamRunning }
            assertTrue("Stack action must report the missing Compose file: ${model.actionStreamOutput}",
                model.actionStreamOutput.contains("No such file", ignoreCase = true) ||
                    model.actionStreamOutput.contains("missing files", ignoreCase = true))
        } finally {
            // Only IDs made by this test; cleanup does not require the deleted Compose file.
            for (id in ids) model.executeSshCommand(host, RemoteCommands.dockerAction(id, "remove", runtime))
            model.executeSshCommand(host, "$runtime network rm ${RemoteCommands.shellQuote("${project}_default")} 2>&1 || true")
            model.executeSshCommand(host, "rm -f ${RemoteCommands.shellQuote(path)}")
            composeRule.runOnUiThread { model.closeActionStream() }
        }
    }

    private suspend fun refresh(model: AppViewModel) {
        composeRule.runOnUiThread { model.loadDocker() }
        await { !model.dockerLoading }
        composeRule.waitForIdle()
    }

    private suspend fun await(predicate: () -> Boolean) = withTimeout(30_000) {
        while (!predicate()) delay(50)
    }
}
