package com.jetsetslow.omniterm.data.mcp

import com.jetsetslow.omniterm.data.Automation
import com.jetsetslow.omniterm.data.MetricHistoryEntity
import com.jetsetslow.omniterm.data.QuickScriptEntity
import com.jetsetslow.omniterm.data.ScriptParams
import com.jetsetslow.omniterm.data.ServerEntity
import com.jetsetslow.omniterm.data.SimContainer
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonArray
import kotlinx.serialization.json.putJsonObject

/** An alert that is firing on a host, as `host_status` reports it. */
data class McpAlert(val metric: String, val mount: String?, val value: Float, val threshold: Float, val severity: String, val since: Long, val acknowledged: Boolean)

/** What the phone is asked to approve before a tool runs anything on a host. */
data class McpApprovalRequest(
    val clientName: String,
    val action: String,
    val hosts: List<String>,
    val command: String,
    val dangerHits: List<String>,
)

/**
 * What the tools need from the app. Only the hosts the user picked for AI assistants are ever
 * passed in or out; the tools never see an address, a user name, a password, a key or a note.
 */
interface McpBackend {
    /** The hosts the user lets AI assistants see, in the app's order. */
    suspend fun exposedHosts(): List<ServerEntity>
    suspend fun latestMetric(serverId: Int): MetricHistoryEntity?
    suspend fun activeAlerts(serverId: Int): List<McpAlert>
    suspend fun scripts(): List<QuickScriptEntity>
    /** Whether the user lets assistants ask for any command, not only saved scripts. */
    suspend fun anyCommandAllowed(): Boolean
    /** The host's containers, or the reason they could not be listed. */
    suspend fun containers(server: ServerEntity): Result<List<SimContainer>>
    /** Asks on the phone; false when the user says no or does not answer in time. */
    suspend fun approve(request: McpApprovalRequest): Boolean
    /** The danger list's hits for [command], shown when approving. */
    fun dangerHits(command: String): List<String>
    /** Runs [script] on [servers]; [values] fill its `{{values}}`, and null runs the command exactly as typed. */
    suspend fun run(script: QuickScriptEntity, servers: List<ServerEntity>, values: Map<String, String>?): Automation.RunResult
}

/**
 * OmniTerm's MCP tools. Reading is free; running anything is approved on the phone each time,
 * whatever the client's own settings say. The tool names and descriptions stay fixed, so a client
 * that pinned them sees no change (tufantunc/ssh-mcp#214).
 */
class McpTools(private val backend: McpBackend) {
    suspend fun all(): List<McpTool> = buildList {
        add(listHosts)
        add(hostStatus)
        add(listContainers)
        add(listScripts)
        add(runScript)
        if (backend.anyCommandAllowed()) add(runCommand)
    }

    private val listHosts = McpTool(
        name = "list_hosts",
        title = "List hosts",
        description = "Lists the servers the OmniTerm user has shared with AI assistants: id, name, group, " +
            "whether OmniTerm last saw it online, its health score (0-100, or null when unknown) and its " +
            "latency. Addresses and sign-in details are never shared. Use the id with the other tools.",
        inputSchema = schema(),
        readOnly = true, destructive = false, idempotent = true, openWorld = false,
    ) { _, _ ->
        val hosts = backend.exposedHosts()
        val rows = buildJsonArray { hosts.forEach { add(hostJson(it)) } }
        structured(buildJsonObject { put("hosts", rows) }, if (hosts.isEmpty()) NO_HOSTS else null)
    }

    private val hostStatus = McpTool(
        name = "host_status",
        title = "Host status",
        description = "Gives a shared host's latest metrics as OmniTerm last measured them (CPU, memory and disk " +
            "use in percent, CPU temperature, network in and out in KB/s, latency) and the alerts firing on it. " +
            "Without host_id, gives every shared host. Reads OmniTerm's own records; nothing runs on the host.",
        inputSchema = schema(optional = mapOf("host_id" to intProp("A host id from list_hosts"))),
        readOnly = true, destructive = false, idempotent = true, openWorld = false,
    ) { args, _ ->
        val hosts = args.optionalInt("host_id")?.let { listOf(host(it)) } ?: backend.exposedHosts()
        val rows = buildJsonArray {
            hosts.forEach { srv ->
                add(
                    buildJsonObject {
                        put("host", hostJson(srv))
                        val m = backend.latestMetric(srv.id)
                        if (m == null) put("metrics", null as String?) else putJsonObject("metrics") {
                            put("measured_at_ms", m.timestamp)
                            put("cpu_percent", m.cpuUsage)
                            put("memory_percent", m.ramUsage)
                            put("disk_percent", m.diskUsage)
                            put("cpu_temperature_c", m.cpuTemperatureC)
                            put("network_in_kbps", m.networkIn)
                            put("network_out_kbps", m.networkOut)
                            put("latency_ms", m.latency)
                        }
                        putJsonArray("alerts") {
                            backend.activeAlerts(srv.id).forEach { a ->
                                add(
                                    buildJsonObject {
                                        put("metric", a.metric)
                                        put("mount", a.mount)
                                        put("value", a.value)
                                        put("threshold", a.threshold)
                                        put("severity", a.severity)
                                        put("since_ms", a.since)
                                        put("acknowledged", a.acknowledged)
                                    },
                                )
                            }
                        }
                    },
                )
            }
        }
        structured(buildJsonObject { put("hosts", rows) }, if (hosts.isEmpty()) NO_HOSTS else null)
    }

    private val listContainers = McpTool(
        name = "list_containers",
        title = "List containers",
        description = "Lists the Docker or Podman containers on a shared host: name, image, state, health, " +
            "published ports and Compose project. Signs in to the host to read them; changes nothing.",
        inputSchema = schema(required = mapOf("host_id" to intProp("A host id from list_hosts"))),
        readOnly = true, destructive = false, idempotent = true, openWorld = true,
    ) { args, _ ->
        val srv = host(args.requiredInt("host_id"))
        val containers = backend.containers(srv).getOrElse { throw McpToolError(it.message ?: "Could not list containers on ${srv.name}") }
        val rows = buildJsonArray {
            containers.forEach { c ->
                add(
                    buildJsonObject {
                        put("name", c.name)
                        put("image", c.image)
                        put("state", c.status)
                        put("health", c.health.takeUnless { it.isBlank() || it == "none" })
                        put("ports", c.ports.ifBlank { null })
                        put("compose_project", c.group.takeUnless { it == "standalone" })
                    },
                )
            }
        }
        structured(buildJsonObject { put("host", hostJson(srv)); put("containers", rows) })
    }

    private val listScripts = McpTool(
        name = "list_scripts",
        title = "List saved scripts",
        description = "Lists the scripts saved in OmniTerm that run_script can run: id, name, category, the OS " +
            "it is for, and the {{values}} it takes with whether each has a default. The commands themselves " +
            "are not shared; the user sees each one when approving it.",
        inputSchema = schema(),
        readOnly = true, destructive = false, idempotent = true, openWorld = false,
    ) { _, _ ->
        val rows = buildJsonArray {
            backend.scripts().forEach { s ->
                add(
                    buildJsonObject {
                        put("id", s.id)
                        put("name", s.name)
                        put("category", s.category)
                        put("target_os", s.targetOs)
                        putJsonArray("values") {
                            ScriptParams.parse(s.command).forEach { p ->
                                add(buildJsonObject { put("name", p.name); put("has_default", p.default.isNotEmpty()) })
                            }
                        }
                    },
                )
            }
        }
        structured(buildJsonObject { put("scripts", rows) })
    }

    private val runScript = McpTool(
        name = "run_script",
        title = "Run a saved script",
        description = "Runs a saved script (an id from list_scripts) on one or more shared hosts and returns each " +
            "host's exit status and output. The OmniTerm user must approve every run on their phone; a run " +
            "they refuse, or do not answer within two minutes, does not happen. values fills the script's " +
            "{{values}}; a value left out uses its default.",
        inputSchema = schema(
            required = mapOf(
                "script_id" to intProp("A script id from list_scripts"),
                "host_ids" to hostIdsProp(),
            ),
            optional = mapOf(
                "values" to buildJsonObject {
                    put("type", "object")
                    put("description", "The script's {{values}} by name")
                    putJsonObject("additionalProperties") { put("type", "string") }
                },
            ),
        ),
        readOnly = false, destructive = true, idempotent = false, openWorld = true,
    ) { args, caller ->
        val script = backend.scripts().find { it.id == args.requiredInt("script_id") }
            ?: throw McpToolError("No saved script has that id; call list_scripts")
        val values = (args["values"] as? JsonObject).orEmpty().mapValues { (name, v) ->
            (v as? JsonPrimitive)?.takeIf { it.isString }?.content ?: throw McpToolError("The value $name must be a string")
        }
        val known = ScriptParams.parse(script.command)
        values.keys.firstOrNull { name -> known.none { it.name == name } }?.let { throw McpToolError("${script.name} has no value called $it") }
        known.firstOrNull { it.default.isEmpty() && values[it.name].isNullOrEmpty() }?.let {
            throw McpToolError("${script.name} needs a value for ${it.name}")
        }
        execute(script, hostsFor(args), values, caller, script.name, shown = ScriptParams.preview(script.command, values))
    }

    private val runCommand = McpTool(
        name = "run_command",
        title = "Run a command",
        description = "Runs one shell command on one or more shared hosts and returns each host's exit status and " +
            "output. Offered only when the OmniTerm user allows any command. The user must approve every run on " +
            "their phone, where the command is shown in full; a run they refuse, or do not answer within two " +
            "minutes, does not happen.",
        inputSchema = schema(
            required = mapOf(
                "command" to buildJsonObject { put("type", "string"); put("description", "The command, as typed into the host's shell") },
                "host_ids" to hostIdsProp(),
            ),
        ),
        readOnly = false, destructive = true, idempotent = false, openWorld = true,
    ) { args, caller ->
        if (!backend.anyCommandAllowed()) throw McpToolError("The OmniTerm user has not allowed any command; use run_script")
        val command = (args["command"] as? JsonPrimitive)?.takeIf { it.isString }?.content?.trim()
            ?.takeIf { it.isNotEmpty() } ?: throw McpToolError("command must be a non-empty string")
        if (command.length > MAX_COMMAND_CHARS) throw McpToolError("command is longer than $MAX_COMMAND_CHARS characters")
        val script = QuickScriptEntity(emoji = "", name = "Command from ${caller.clientName}", command = command, color = "cyan")
        // A typed command is not a template: braces in it are the shell's, not values to fill.
        execute(script, hostsFor(args), values = null, caller, command, shown = command)
    }

    private suspend fun execute(
        script: QuickScriptEntity,
        hosts: List<ServerEntity>,
        values: Map<String, String>?,
        caller: McpCaller,
        action: String,
        shown: String,
    ): McpToolResult {
        val approved = backend.approve(
            McpApprovalRequest(caller.clientName, action, hosts.map { it.name }, shown, backend.dangerHits(shown)),
        )
        if (!approved) throw McpToolError("The OmniTerm user did not approve this run, so nothing ran")
        val result = backend.run(script, hosts, values)
        result.error?.let { throw McpToolError(it) }
        val rows = buildJsonArray {
            result.hosts.forEach { h ->
                add(
                    buildJsonObject {
                        put("host_id", h.serverId)
                        put("name", h.name)
                        put("ran", h.exit != null)
                        put("exit", h.exit)
                        put("output", tail(h.output))
                        put("note", h.note)
                    },
                )
            }
        }
        return McpToolResult(
            text = result.combinedOutput().ifBlank { result.errorMessage ?: "Done; no output." },
            structured = buildJsonObject {
                put("succeeded", result.succeeded)
                put("hosts", rows)
            },
            isError = !result.succeeded,
        )
    }

    private suspend fun host(id: Int): ServerEntity =
        backend.exposedHosts().find { it.id == id } ?: throw McpToolError("No shared host has id $id; call list_hosts")

    private suspend fun hostsFor(args: JsonObject): List<ServerEntity> {
        val ids = (args["host_ids"] as? JsonArray)?.map { (it as? JsonPrimitive)?.wholeNumber() ?: throw McpToolError("host_ids must be numbers") }
            ?: throw McpToolError("host_ids is required")
        if (ids.isEmpty()) throw McpToolError("host_ids must name at least one host")
        if (ids.size > MAX_HOSTS) throw McpToolError("At most $MAX_HOSTS hosts at once")
        val shared = backend.exposedHosts().associateBy { it.id }
        return ids.distinct().map { shared[it] ?: throw McpToolError("No shared host has id $it; call list_hosts") }
    }

    private fun hostJson(srv: ServerEntity) = buildJsonObject {
        put("id", srv.id)
        put("name", srv.name)
        put("group", srv.groupName)
        put("online", srv.status == "online")
        put("health_score", srv.healthScore.takeIf { it in 0..100 })
        put("latency_ms", srv.lastLatency.takeIf { it > 0 })
    }

    private fun structured(data: JsonObject, text: String? = null) = McpToolResult(text ?: data.toString(), data)

    private fun tail(text: String) = if (text.length > HOST_OUTPUT_CHARS) text.takeLast(HOST_OUTPUT_CHARS) else text

    companion object {
        const val MAX_HOSTS = 20
        const val MAX_COMMAND_CHARS = 8_000
        const val HOST_OUTPUT_CHARS = 16_000
        private const val NO_HOSTS = "The OmniTerm user has not shared any hosts with AI assistants."

        private fun JsonObject.optionalInt(key: String): Int? = when (val v = this[key]) {
            null -> null
            is JsonPrimitive -> v.wholeNumber() ?: throw McpToolError("$key must be a number")
            else -> throw McpToolError("$key must be a number")
        }

        /** A JSON number with no fraction; "1" in quotes is a string, as the schema says. */
        private fun JsonPrimitive.wholeNumber(): Int? = if (isString) null else intOrNull

        private fun JsonObject.requiredInt(key: String): Int = optionalInt(key) ?: throw McpToolError("$key is required")

        private fun intProp(description: String) = buildJsonObject { put("type", "integer"); put("description", description) }

        private fun hostIdsProp() = buildJsonObject {
            put("type", "array")
            put("description", "Host ids from list_hosts")
            putJsonObject("items") { put("type", "integer") }
            put("minItems", 1)
            put("maxItems", MAX_HOSTS)
        }

        private fun schema(required: Map<String, JsonObject> = emptyMap(), optional: Map<String, JsonObject> = emptyMap()) = buildJsonObject {
            put("type", "object")
            putJsonObject("properties") { (required + optional).forEach { (k, v) -> put(k, v) } }
            if (required.isNotEmpty()) putJsonArray("required") { required.keys.forEach { add(JsonPrimitive(it)) } }
            put("additionalProperties", false)
        }
    }
}
