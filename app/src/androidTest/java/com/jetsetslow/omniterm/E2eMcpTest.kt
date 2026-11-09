package com.jetsetslow.omniterm

import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.assert
import androidx.compose.ui.test.hasTestTag
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.performClick
import androidx.lifecycle.ViewModelProvider
import androidx.test.platform.app.InstrumentationRegistry
import com.jetsetslow.omniterm.data.AppDatabase
import com.jetsetslow.omniterm.data.AppRepository
import com.jetsetslow.omniterm.data.HostCredentials
import com.jetsetslow.omniterm.data.McpCallOutcome
import com.jetsetslow.omniterm.data.ServerEntity
import com.jetsetslow.omniterm.data.mcp.Mcp
import com.jetsetslow.omniterm.data.mcp.McpSettings
import com.jetsetslow.omniterm.data.ssh.JschSshTransport
import com.jetsetslow.omniterm.ui.AppViewModel
import com.jetsetslow.omniterm.ui.Screen
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Rule
import org.junit.Test
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/**
 * The MCP server against the repository's provisioned disposable host, as a user sets it up: the
 * host is shared and picked to reach the phone through, the server is turned on from Tools → AI
 * assistants, and its token is read from the one time it is shown. From the host, curl then:
 * - discovers the server (2026-07-28) and initializes as a 2025 client;
 * - lists hosts and gets the host's name but never its address or user;
 * - is refused with the wrong token or a web page's origin;
 * - asks to run a command, which waits for the phone: denied, it does not run; approved, it does.
 * Turning the server off closes the port on the host. Every setting is put back.
 */
class E2eMcpTest {
    @get:Rule val composeRule = createAndroidComposeRule<MainActivity>()

    @Test fun anAssistantOnAHostReachesThePhoneAndRunsOnlyWhatIsApproved() {
        val args = InstrumentationRegistry.getArguments()
        assumeTrue(args.getString("omniterm_e2e_mcp") == "yes")
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val repository = AppRepository(AppDatabase.getDatabase(context))
        val vm = ViewModelProvider(composeRule.activity)[AppViewModel::class.java]
        composeRule.waitUntil(15_000) { vm.servers.value.any { it.name == HOST } }
        val host: ServerEntity = vm.servers.value.single { it.name == HOST }
        assertEquals("Use the repository fixture endpoint", args.getString("host", "127.0.0.1"), host.host)
        assertTrue("start from the server off", runBlocking { repository.getSetting(McpSettings.ENABLED) } != "true")
        val creds = runBlocking { HostCredentials.build(repository, host, posixShell = true) }
        val transport = JschSshTransport()
        fun has(tag: String) = composeRule.showsNode(hasTestTag(tag))
        fun sh(command: String, stdin: String? = null) = runBlocking { transport.exec(creds, command, stdin) }
        val port = 40_000 + (System.currentTimeMillis() % 10_000).toInt()
        val stamp = System.currentTimeMillis().toString()

        /** One POST from the host through the tunnel: the status and the body. */
        fun post(token: String, body: String, headers: Map<String, String> = emptyMap()): Pair<Int, String> {
            val extra = headers.entries.joinToString(" ") { "-H '${it.key}: ${it.value}'" }
            val out = sh(
                "curl -s -m 170 -w '\\n%{http_code}' -X POST http://127.0.0.1:$port/mcp " +
                    "-H 'Authorization: Bearer $token' -H 'Content-Type: application/json' " +
                    "-H 'Accept: application/json, text/event-stream' $extra --data-binary @-",
                stdin = body,
            )
            if (out.startsWith("SSH Error")) return 0 to out
            val code = out.trimEnd().substringAfterLast('\n').trim().toIntOrNull() ?: 0
            return code to out.trimEnd().substringBeforeLast('\n')
        }
        val meta = """"_meta":{"${Mcp.META_VERSION}":"${Mcp.MODERN}","${Mcp.META_CLIENT_CAPABILITIES}":{},"${Mcp.META_CLIENT_INFO}":{"name":"e2e-curl","version":"1"}}"""
        fun modern(method: String, name: String? = null) = buildMap {
            put("MCP-Protocol-Version", Mcp.MODERN)
            put("Mcp-Method", method)
            name?.let { put("Mcp-Name", it) }
        }

        try {
            // What the user picks: this host shared, reached through, any command allowed.
            composeRule.runOnUiThread {
                vm.saveMcpHosts(listOf(host.id))
                vm.saveMcpTunnel(host.id, port)
                vm.saveMcpAnyCommand(true)
            }
            composeRule.waitUntil(10_000) {
                vm.mcpConfig.value.let { it.tunnelHostId == host.id && it.tunnelPort == port && host.id in it.hostIds && it.anyCommand }
            }

            // Turned on from the screen: it asks, makes a token, and shows it once.
            composeRule.runOnUiThread { vm.navigateTo(Screen.Mcp) }
            composeRule.waitUntil(15_000) { has("mcp.enabled") }
            composeRule.onNodeWithTag("mcp.privacy").assertExists()
            composeRule.onNodeWithTag("mcp.enabled").performClick()
            composeRule.waitUntil(15_000) { has("mcp.confirm") }
            composeRule.onNodeWithTag("mcp.confirm").performClick()
            composeRule.waitUntil(15_000) { has("mcp.token") }
            val token = composeRule.onNodeWithTag("mcp.token").fetchSemanticsNode()
                .config[SemanticsProperties.Text].joinToString("") { it.text }
            assertTrue("a token is shown: ${token.length} characters", token.startsWith("omt_") && token.length == 26)
            assertEquals("only its hash is kept", runBlocking { repository.getSetting(McpSettings.TOKEN_HASH) }?.length, 64)
            composeRule.onNodeWithTag("mcp.token.done").performClick()
            composeRule.waitUntil(60_000) { vm.mcpState.value.running && vm.mcpState.value.tunnelUp }
            val listening = sh("netstat -ltn 2>/dev/null || ss -ltn")
            assertTrue("the host listens on its own loopback address", listening.contains("127.0.0.1:$port"))
            assertFalse("and not on the network", listening.contains("0.0.0.0:$port") || listening.contains(":::$port"))

            // A 2026-07-28 client, then a 2025 one.
            val (discoverStatus, discover) = post(token, """{"jsonrpc":"2.0","id":1,"method":"server/discover","params":{$meta}}""", modern("server/discover"))
            assertEquals(discover, 200, discoverStatus)
            assertTrue(discover, discover.contains("\"supportedVersions\"") && discover.contains("\"resultType\":\"complete\""))
            val (initStatus, init) = post(token, """{"jsonrpc":"2.0","id":2,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"old","version":"1"}}}""")
            assertEquals(init, 200, initStatus)
            assertTrue(init, init.contains("\"protocolVersion\":\"2025-06-18\""))
            val (_, list) = post(token, """{"jsonrpc":"2.0","id":3,"method":"tools/list"}""", mapOf("MCP-Protocol-Version" to "2025-06-18"))
            assertTrue(list, list.contains("\"run_command\"") && list.contains("\"readOnlyHint\":true"))

            // The host by name, never by address or user.
            val (_, hosts) = post(token, """{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"list_hosts",$meta}}""", modern("tools/call", "list_hosts"))
            // Only the host entries: the server's own name, "omniterm", may well be the fixture's user.
            val entries = hosts.substringAfter("\"structuredContent\"").substringBefore("\"_meta\"")
            assertTrue(hosts, entries.contains(HOST))
            assertFalse("no address: $entries", entries.contains(host.host))
            assertFalse("no user: $entries", entries.contains("\"${host.username}\""))

            // Turned away.
            assertEquals(401, post("omt_wrong-token-0123456789", """{"jsonrpc":"2.0","id":5,"method":"tools/list"}""").first)
            assertEquals(403, post(token, """{"jsonrpc":"2.0","id":6,"method":"tools/list"}""", mapOf("Origin" to "https://evil.example")).first)

            // A command waits for the phone. Denied, it does not run.
            val marker = "/tmp/mcp-e2e-$stamp"
            fun ran() = sh("[ -e $marker ] && echo yes || echo no").trim() == "yes"
            val command = "echo mcp-e2e-$stamp && touch $marker"
            val body = """{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"run_command","arguments":{"command":"$command","host_ids":[${host.id}]},$meta}}"""
            val pool = Executors.newSingleThreadExecutor()
            try {
                val denied = pool.submit<Pair<Int, String>> { post(token, body, modern("tools/call", "run_command")) }
                composeRule.waitUntil(30_000) { has("mcp.approval") }
                composeRule.onNodeWithTag("mcp.approval.command", useUnmergedTree = true).assert(hasText(command))
                composeRule.onNodeWithTag("mcp.approval.deny").performClick()
                val (deniedStatus, deniedText) = denied.get(60, TimeUnit.SECONDS)
                assertEquals(deniedText, 200, deniedStatus)
                assertTrue(deniedText, deniedText.contains("did not approve") && deniedText.contains("\"isError\":true"))
                assertFalse("a denied command does not run", ran())

                // Approved, behind the lock (a plain confirm on a phone without one), it runs.
                val approved = pool.submit<Pair<Int, String>> { post(token, body.replace("\"id\":7", "\"id\":8"), modern("tools/call", "run_command")) }
                composeRule.waitUntil(30_000) { has("mcp.approval") }
                composeRule.onNodeWithTag("mcp.approval.approve").performClick()
                composeRule.waitUntil(15_000) { has("mcp.approval.confirm") }
                composeRule.onNodeWithTag("mcp.approval.confirm").performClick()
                val (okStatus, okText) = approved.get(150, TimeUnit.SECONDS)
                assertEquals(okText, 200, okStatus)
                assertTrue(okText, okText.contains("mcp-e2e-$stamp") && okText.contains("\"isError\":false"))
                assertTrue("an approved command runs", ran())
                composeRule.waitUntil(5_000) { !has("mcp.approval") }
            } finally {
                pool.shutdownNow()
            }

            // Every call is in the record, with what came of it.
            val calls = runBlocking { repository.mcpCallsFlow.first() }
            assertTrue(calls.toString(), calls.any { it.tool == "list_hosts" && it.outcome == McpCallOutcome.OK && it.client == "e2e-curl" })
            assertTrue(calls.toString(), calls.any { it.tool == "run_command" && it.outcome == McpCallOutcome.FAILED })
            assertTrue(calls.toString(), calls.any { it.tool == "run_command" && it.outcome == McpCallOutcome.OK })
            assertTrue(calls.toString(), calls.any { it.outcome == McpCallOutcome.REFUSED })

            // Off: the host's port closes.
            composeRule.runOnUiThread { vm.saveMcpEnabled(false) }
            composeRule.waitUntil(15_000) { !vm.mcpState.value.running }
            composeRule.waitUntil(20_000) { !sh("netstat -ltn 2>/dev/null || ss -ltn").contains("127.0.0.1:$port") }
            assertEquals(0, post(token, """{"jsonrpc":"2.0","id":9,"method":"tools/list"}""").first)
        } finally {
            composeRule.runOnUiThread { vm.saveMcpEnabled(false) }
            runBlocking {
                McpSettings.ALL.forEach { repository.deleteSetting(it) }
                repository.clearMcpCalls()
            }
            runCatching { sh("rm -f /tmp/mcp-e2e-$stamp") }
            transport.shutdown()
        }
    }

    private companion object {
        const val HOST = "E2E Foreground Demo"
    }
}
