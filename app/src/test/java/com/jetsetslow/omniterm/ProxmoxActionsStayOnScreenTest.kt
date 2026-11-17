package com.jetsetslow.omniterm

import com.google.common.truth.Truth.assertWithMessage
import org.junit.Test
import java.io.File

/**
 * Guest power actions and snapshot changes are for the person holding the phone: they run only from
 * the Proxmox screen, never from schedules, alert runbooks, Tasker intents, the MCP server or the AI
 * assistants. A source scan on purpose, so a new caller anywhere in the app fails here, not in review.
 */
class ProxmoxActionsStayOnScreenTest {
    private val sources = generateSequence(File("").absoluteFile) { it.parentFile }
        .map { File(it, "app/src/main/java").takeIf(File::isDirectory) ?: File(it, "src/main/java") }
        .first { it.isDirectory }

    private val files = sources.walkTopDown().filter { it.extension == "kt" }.associate { it.name to it.readText() }

    @Test
    fun onlyTheProxmoxScreenAndItsModelUseTheClient() {
        val users = files.filterValues { "ProxmoxApi" in it }.keys
        assertWithMessage("files that use the Proxmox client").that(users)
            .containsExactly("ProxmoxApi.kt", "ProxmoxScreen.kt", "AppViewModel.kt")
        // The transport under it could send a guest action too, so it is only built for the client.
        val transports = files.filterValues { "ProxmoxTransport" in it }.keys
        assertWithMessage("files that use the Proxmox transport").that(transports)
            .containsExactly("ProxmoxApi.kt", "ProxmoxOkHttp.kt", "AppViewModel.kt")
        assertWithMessage("the model builds a transport only to hand it to the client")
            .that(Regex("""\w*ProxmoxTransport\(""").findAll(files.getValue("AppViewModel.kt")).map { it.value }.toList())
            .containsExactly("OkHttpProxmoxTransport(")
        assertWithMessage("and only inside ProxmoxApi(…)").that(files.getValue("AppViewModel.kt"))
            .contains("ProxmoxApi(OkHttpProxmoxTransport(server, tunnelNow))")
    }

    @Test
    fun guestActionsAreStartedOnlyFromTheScreen() {
        val callers = files.filterValues { "proxmoxAction(" in it }.keys
        assertWithMessage("files that start a guest action").that(callers).containsExactly("ProxmoxScreen.kt", "AppViewModel.kt")
        val model = files.getValue("AppViewModel.kt")
        assertWithMessage("the model only defines it").that(Regex("""proxmoxAction\(""").findAll(model).count()).isEqualTo(1)
        val used = Regex("""proxmoxApi\(\w+\)\.(\w+)""").findAll(model).map { it.groupValues[1] }.toSet()
        assertWithMessage("what the model itself does with the client").that(used).containsExactly("overview", "snapshots", "action")
    }
}
