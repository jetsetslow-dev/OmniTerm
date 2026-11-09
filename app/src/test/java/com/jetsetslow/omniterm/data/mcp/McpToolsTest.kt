package com.jetsetslow.omniterm.data.mcp

import com.google.common.truth.Truth.assertThat
import com.google.common.truth.Truth.assertWithMessage
import com.jetsetslow.omniterm.data.Automation
import com.jetsetslow.omniterm.data.MetricHistoryEntity
import com.jetsetslow.omniterm.data.QuickScriptEntity
import com.jetsetslow.omniterm.data.ServerEntity
import com.jetsetslow.omniterm.data.SimContainer
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Test

/** OmniTerm's MCP tools against a fake app: what they share, and that nothing runs unapproved. */
class McpToolsTest {
    /** Every string here is something no tool may ever hand to an assistant. */
    private val secrets = listOf("10.9.8.7", "rootuser", "Pa55-secret", "sudo-secret", "note-secret", "proxy.secret", "key-secret", "secret-cmd-text")

    private val shared = ServerEntity(
        id = 1, name = "nas", host = "10.9.8.7", username = "rootuser", authPassword = "Pa55-secret",
        sudoPassword = "sudo-secret", notes = "note-secret", proxyHost = "proxy.secret", authKeyAlias = "key-secret",
        groupName = "Homelab", status = "online", healthScore = 87, lastLatency = 12,
    )
    private val alsoShared = shared.copy(id = 2, name = "pi", status = "offline", healthScore = -1, lastLatency = 0)
    private val hidden = shared.copy(id = 3, name = "bank")

    private val backup = QuickScriptEntity(id = 10, emoji = "", name = "Backup", command = "secret-cmd-text {{dest=/srv}} {{tag}}", color = "cyan", category = "Ops", targetOs = "Linux")
    private val uptime = QuickScriptEntity(id = 11, emoji = "", name = "Uptime", command = "uptime", color = "cyan")

    private inner class Fake : McpBackend {
        var exposed = setOf(1, 2)
        var anyCommand = false
        var answer = true
        val approvals = mutableListOf<McpApprovalRequest>()
        val runs = mutableListOf<Triple<QuickScriptEntity, List<Int>, Map<String, String>?>>()

        override suspend fun exposedHosts() = listOf(shared, alsoShared, hidden).filter { it.id in exposed }
        override suspend fun latestMetric(serverId: Int) =
            if (serverId == 1) MetricHistoryEntity(serverId = 1, timestamp = 5_000, cpuUsage = 42.5f, ramUsage = 61f, diskUsage = 90f, latency = 12, networkIn = 1f, networkOut = 2f) else null
        override suspend fun activeAlerts(serverId: Int) =
            if (serverId == 1) listOf(McpAlert("Disk Usage", "/srv", 90f, 85f, "WARNING", 4_000, false)) else emptyList()
        override suspend fun scripts() = listOf(backup, uptime)
        override suspend fun anyCommandAllowed() = anyCommand
        override suspend fun containers(server: ServerEntity) = Result.success(
            listOf(
                SimContainer("abc", "jellyfin", "jellyfin/jellyfin", "8096->8096/tcp", "running", "media", server.id, health = "healthy"),
                SimContainer("def", "db", "postgres:16", "", "exited", "standalone", server.id),
            ),
        )
        override suspend fun approve(request: McpApprovalRequest): Boolean { approvals += request; return answer }
        override fun dangerHits(command: String) = if ("rm -rf" in command) listOf("rm -rf") else emptyList()
        override suspend fun run(script: QuickScriptEntity, servers: List<ServerEntity>, values: Map<String, String>?): Automation.RunResult {
            runs += Triple(script, servers.map { it.id }, values)
            return Automation.RunResult(servers.map { Automation.HostResult(it.id, it.name, 0, "ok from ${it.name}\n") })
        }
    }

    private val fake = Fake()
    private val tools = McpTools(fake)
    private val caller = McpCaller("Claude Code")

    private fun call(name: String, args: String = "{}"): McpToolResult = runBlocking {
        val tool = tools.all().find { it.name == name } ?: error("no tool $name")
        try {
            tool.call(Json.parseToJsonElement(args).jsonObject, caller)
        } catch (e: McpToolError) {
            McpToolResult(e.message.orEmpty(), isError = true)
        }
    }

    private fun assertNoSecrets(result: McpToolResult) {
        val everything = result.text + result.structured.toString()
        secrets.forEach { assertWithMessage("never shares $it").that(everything).doesNotContain(it) }
    }

    private fun names(): List<String> = runBlocking { tools.all().map { it.name } }

    @Test
    fun hostsAreListedWithoutAddressesOrSignInDetails() {
        val result = call("list_hosts")
        assertNoSecrets(result)
        val hosts = result.structured!!["hosts"]!!.jsonArray.map { it.jsonObject }
        assertThat(hosts.map { it["name"]!!.jsonPrimitive.content }).containsExactly("nas", "pi").inOrder()
        assertThat(hosts.first().keys).containsExactly("id", "name", "group", "online", "health_score", "latency_ms")
        assertThat(hosts.first()["health_score"]!!.jsonPrimitive.content).isEqualTo("87")
        assertWithMessage("an unknown score is null, not -1").that(hosts.last()["health_score"].toString()).isEqualTo("null")
        assertWithMessage("a host not shared is not listed").that(result.structured.toString()).doesNotContain("bank")
    }

    @Test
    fun noHostsSharedSaysSo() {
        fake.exposed = emptySet()
        assertThat(call("list_hosts").text).contains("has not shared any hosts")
        assertThat(call("host_status").text).contains("has not shared any hosts")
    }

    @Test
    fun statusComesFromOmniTermsOwnRecords() {
        val result = call("host_status", """{"host_id":1}""")
        assertNoSecrets(result)
        val host = result.structured!!["hosts"]!!.jsonArray.single().jsonObject
        assertThat(host["metrics"]!!.jsonObject["cpu_percent"]!!.jsonPrimitive.content).isEqualTo("42.5")
        val alert = host["alerts"]!!.jsonArray.single().jsonObject
        assertThat(alert["mount"]!!.jsonPrimitive.content).isEqualTo("/srv")
        assertThat(alert["severity"]!!.jsonPrimitive.content).isEqualTo("WARNING")
        assertThat(call("host_status").structured!!["hosts"]!!.jsonArray).hasSize(2)
        assertThat(call("host_status", """{"host_id":2}""").structured.toString()).contains("\"metrics\":null")
    }

    @Test
    fun aHostNotSharedCannotBeReadOrRunOn() {
        listOf(
            "host_status" to """{"host_id":3}""",
            "list_containers" to """{"host_id":3}""",
            "run_script" to """{"script_id":11,"host_ids":[1,3]}""",
        ).forEach { (tool, args) ->
            val result = call(tool, args)
            assertWithMessage(tool).that(result.isError).isTrue()
            assertWithMessage(tool).that(result.text).contains("No shared host has id 3")
        }
        assertWithMessage("nothing was even asked").that(fake.approvals).isEmpty()
        assertThat(fake.runs).isEmpty()
    }

    @Test
    fun containersAreListed() {
        val result = call("list_containers", """{"host_id":1}""")
        val rows = result.structured!!["containers"]!!.jsonArray.map { it.jsonObject }
        assertThat(rows.first()["health"]!!.jsonPrimitive.content).isEqualTo("healthy")
        assertThat(rows.first()["compose_project"]!!.jsonPrimitive.content).isEqualTo("media")
        assertThat(rows.last()["compose_project"].toString()).isEqualTo("null")
        assertThat(rows.last()["health"].toString()).isEqualTo("null")
        assertThat(call("list_containers").isError).isTrue()
    }

    @Test
    fun scriptsAreListedWithoutTheirCommands() {
        val result = call("list_scripts")
        assertNoSecrets(result)
        val first = result.structured!!["scripts"]!!.jsonArray.first().jsonObject
        assertThat(first["name"]!!.jsonPrimitive.content).isEqualTo("Backup")
        assertThat(first["values"].toString()).isEqualTo("""[{"name":"dest","has_default":true},{"name":"tag","has_default":false}]""")
    }

    @Test
    fun aScriptRunsOnlyAfterTheUserApprovesIt() {
        fake.answer = false
        val refused = call("run_script", """{"script_id":10,"host_ids":[1,2],"values":{"tag":"nightly"}}""")
        assertThat(refused.isError).isTrue()
        assertThat(refused.text).contains("did not approve")
        assertWithMessage("a refused run does not happen").that(fake.runs).isEmpty()
        val asked = fake.approvals.single()
        assertThat(asked.clientName).isEqualTo("Claude Code")
        assertThat(asked.hosts).containsExactly("nas", "pi").inOrder()
        assertWithMessage("the user sees the command filled in").that(asked.command).isEqualTo("secret-cmd-text /srv nightly")

        fake.answer = true
        val ran = call("run_script", """{"script_id":10,"host_ids":[2,1,2],"values":{"tag":"nightly"}}""")
        assertThat(ran.isError).isFalse()
        assertThat(fake.runs.single().second).containsExactly(2, 1).inOrder()
        assertThat(fake.runs.single().third).containsExactly("tag", "nightly")
        assertThat(ran.structured!!["succeeded"]!!.jsonPrimitive.content).isEqualTo("true")
        assertThat(ran.text).contains("ok from nas")
    }

    @Test
    fun badRunArgumentsAreRefusedBeforeAsking() {
        listOf(
            """{"script_id":10,"host_ids":[1]}""" to "needs a value for tag",
            """{"script_id":10,"host_ids":[1],"values":{"tag":"x","other":"y"}}""" to "has no value called other",
            """{"script_id":10,"host_ids":[1],"values":{"tag":5}}""" to "must be a string",
            """{"script_id":99,"host_ids":[1]}""" to "No saved script has that id",
            """{"script_id":11,"host_ids":[]}""" to "at least one host",
            """{"script_id":11}""" to "host_ids is required",
            """{"script_id":11,"host_ids":["1"]}""" to "host_ids must be numbers",
            """{"script_id":"11","host_ids":[1]}""" to "script_id must be a number",
            """{"script_id":11,"host_ids":[${(1..21).joinToString(",")}]}""" to "At most 20 hosts",
        ).forEach { (args, why) ->
            val result = call("run_script", args)
            assertWithMessage(args).that(result.isError).isTrue()
            assertWithMessage(args).that(result.text).contains(why)
        }
        assertThat(fake.approvals).isEmpty()
        assertThat(fake.runs).isEmpty()
    }

    @Test
    fun anyCommandIsOfferedOnlyWhenAllowedAndRunsExactlyAsTyped() {
        assertThat(names()).doesNotContain("run_command")
        fake.anyCommand = true
        assertThat(names()).containsExactly("list_hosts", "host_status", "list_containers", "list_scripts", "run_script", "run_command")
        val typed = "docker inspect --format '{{.State.Status}}' db && rm -rf /tmp/x"
        val result = call("run_command", Json.encodeToString(JsonObject.serializer(), JsonObject(mapOf(
            "command" to kotlinx.serialization.json.JsonPrimitive(typed),
            "host_ids" to Json.parseToJsonElement("[1]"),
        ))))
        assertThat(result.isError).isFalse()
        val asked = fake.approvals.single()
        assertThat(asked.command).isEqualTo(typed)
        assertThat(asked.dangerHits).containsExactly("rm -rf")
        assertWithMessage("braces are the shell's, not values").that(fake.runs.single().third).isNull()
        assertThat(fake.runs.single().first.command).isEqualTo(typed)

        fake.anyCommand = false
        val stale = runBlocking {
            McpTools(fake.also { it.anyCommand = true }).all().first { it.name == "run_command" }.let { tool ->
                fake.anyCommand = false
                runCatching { tool.call(Json.parseToJsonElement("""{"command":"id","host_ids":[1]}""").jsonObject, caller) }
            }
        }
        assertWithMessage("turning it off stops a client holding the old list").that(stale.exceptionOrNull()).isInstanceOf(McpToolError::class.java)
        assertThat(fake.runs).hasSize(1)
    }

    @Test
    fun theHintsSayWhatEachToolDoes() = runBlocking {
        fake.anyCommand = true
        val all = tools.all().associateBy { it.name }
        listOf("list_hosts", "host_status", "list_containers", "list_scripts").forEach {
            assertWithMessage(it).that(all.getValue(it).readOnly).isTrue()
            assertWithMessage(it).that(all.getValue(it).destructive).isFalse()
        }
        listOf("run_script", "run_command").forEach {
            assertWithMessage(it).that(all.getValue(it).readOnly).isFalse()
            assertWithMessage(it).that(all.getValue(it).destructive).isTrue()
            assertWithMessage(it).that(all.getValue(it).description).contains("approve")
        }
        assertWithMessage("only reading the host itself is open-world").that(all.getValue("host_status").openWorld).isFalse()
    }
}
