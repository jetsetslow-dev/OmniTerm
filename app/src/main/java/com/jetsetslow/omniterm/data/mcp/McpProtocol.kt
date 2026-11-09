package com.jetsetslow.omniterm.data.mcp

import kotlinx.coroutines.CancellationException
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonArray
import kotlinx.serialization.json.putJsonObject

/**
 * The Model Context Protocol as OmniTerm's local server speaks it: tools only, one JSON-RPC
 * request per HTTP POST, answered with one JSON body and no session.
 *
 * Two eras are served side by side. A 2026-07-28 request carries its version and the client's
 * capabilities in `params._meta` and repeats the method (and a tool's name) in headers; there is no
 * handshake, and `server/discover` says what the server offers. An older client sends `initialize`
 * first and then plain requests; those get the 2025 shapes, without a session id, which the 2025
 * Streamable HTTP transport allows.
 *
 * Pure Kotlin with no Android types, so it can move to the shared module unchanged.
 *
 * Credit: built from the specification at modelcontextprotocol.io (versions 2026-07-28 and
 * 2025-03-26 to 2025-11-25). A GET answers 405 rather than an empty body, which electerm#4431 found
 * clients choke on; tools carry read-only and destructive hints (tufantunc/ssh-mcp#36) and fixed
 * descriptions (tufantunc/ssh-mcp#214). No code is copied from any of them.
 */
object Mcp {
    const val MODERN = "2026-07-28"
    /** Older versions, newest first: an `initialize` asking for one gets it, anything else the first. */
    val LEGACY = listOf("2025-11-25", "2025-06-18", "2025-03-26")
    val SUPPORTED = listOf(MODERN) + LEGACY

    const val META_VERSION = "io.modelcontextprotocol/protocolVersion"
    const val META_CLIENT_CAPABILITIES = "io.modelcontextprotocol/clientCapabilities"
    const val META_CLIENT_INFO = "io.modelcontextprotocol/clientInfo"
    const val META_SERVER_INFO = "io.modelcontextprotocol/serverInfo"

    const val HEADER_VERSION = "mcp-protocol-version"
    const val HEADER_METHOD = "mcp-method"
    const val HEADER_NAME = "mcp-name"

    const val PARSE_ERROR = -32700
    const val INVALID_REQUEST = -32600
    const val METHOD_NOT_FOUND = -32601
    const val INVALID_PARAMS = -32602
    const val INTERNAL_ERROR = -32603
    const val HEADER_MISMATCH = -32020
    const val UNSUPPORTED_VERSION = -32022

    /** How long a client may reuse `server/discover` and `tools/list`: the tool list changes with settings. */
    const val LIST_TTL_MS = 60_000L

    /** The longest client name kept in the record of calls. */
    const val CLIENT_NAME_CHARS = 64

    val json = Json { explicitNulls = false }
}

/** Who is calling, as far as the request says: the client's own name, for the record of calls. */
data class McpCaller(val clientName: String)

/** What a tool returns: text for the model, the same as JSON when the tool has an output shape. */
data class McpToolResult(val text: String, val structured: JsonObject? = null, val isError: Boolean = false)

/** A tool's refusal or a bad argument, returned to the model as an error result it can act on. */
class McpToolError(message: String) : Exception(message)

/**
 * One tool. The hints say what it does to hosts, for clients that ask before calling: a client may
 * ignore them, so a tool that changes anything is also approved on the phone.
 */
class McpTool(
    val name: String,
    val title: String,
    val description: String,
    val inputSchema: JsonObject,
    val readOnly: Boolean,
    val destructive: Boolean,
    val idempotent: Boolean,
    val openWorld: Boolean,
    val outputSchema: JsonObject? = null,
    val call: suspend (arguments: JsonObject, caller: McpCaller) -> McpToolResult,
) {
    fun describe(): JsonObject = buildJsonObject {
        put("name", name)
        put("title", title)
        put("description", description)
        put("inputSchema", inputSchema)
        outputSchema?.let { put("outputSchema", it) }
        putJsonObject("annotations") {
            put("title", title)
            put("readOnlyHint", readOnly)
            put("destructiveHint", destructive)
            put("idempotentHint", idempotent)
            put("openWorldHint", openWorld)
        }
    }
}

/** An HTTP answer: [body] null means 202 with nothing in it, the answer to a notification. */
data class McpReply(val status: Int, val body: String?)

/**
 * Answers one request body. [headers] have lower-case names. [tools] is read for every request, so
 * a change in settings shows at once. [onCall] hears every `tools/call`, for the record of calls.
 */
class McpHandler(
    private val serverName: String,
    private val serverTitle: String,
    private val serverVersion: String,
    private val instructions: String,
    private val tools: suspend () -> List<McpTool>,
    private val onCall: suspend (caller: McpCaller, tool: String, result: McpToolResult) -> Unit = { _, _, _ -> },
) {
    suspend fun handle(body: String, headers: Map<String, String>): McpReply {
        val element = try {
            Json.parseToJsonElement(body)
        } catch (e: Exception) {
            if (e is CancellationException) throw e
            return error(400, JsonNull, Mcp.PARSE_ERROR, "The body is not JSON")
        }
        if (element is JsonArray) return error(400, JsonNull, Mcp.INVALID_REQUEST, "Send one request per POST; batches are not supported")
        val message = element as? JsonObject ?: return error(400, JsonNull, Mcp.INVALID_REQUEST, "Expected a JSON-RPC request")
        val id = message["id"]
        val method = (message["method"] as? JsonPrimitive)?.takeIf { it.isString }?.content
        if ((message["jsonrpc"] as? JsonPrimitive)?.contentOrNull != "2.0" || method == null) {
            // A response or anything else a client might post: nothing to answer.
            if (id == null && method == null && (message.containsKey("result") || message.containsKey("error"))) return McpReply(202, null)
            return error(400, id ?: JsonNull, Mcp.INVALID_REQUEST, "Expected a JSON-RPC 2.0 request")
        }
        if (id == null) return McpReply(202, null)
        if (id !is JsonPrimitive || id is JsonNull) return error(400, JsonNull, Mcp.INVALID_REQUEST, "The id must be a string or a number")
        val params = message["params"] as? JsonObject ?: JsonObject(emptyMap())
        val meta = params["_meta"] as? JsonObject
        return if (meta?.get(Mcp.META_VERSION) != null) modern(id, method, params, meta, headers)
        else legacy(id, method, params, headers)
    }

    private suspend fun modern(id: JsonElement, method: String, params: JsonObject, meta: JsonObject, headers: Map<String, String>): McpReply {
        val requested = (meta[Mcp.META_VERSION] as? JsonPrimitive)?.contentOrNull
        if (requested != Mcp.MODERN) {
            return error(
                400, id, Mcp.UNSUPPORTED_VERSION, "Unsupported protocol version: $requested",
                buildJsonObject {
                    putJsonArray("supported") { Mcp.SUPPORTED.forEach { add(JsonPrimitive(it)) } }
                    put("requested", requested)
                },
            )
        }
        headerMismatch(Mcp.HEADER_VERSION, requested, headers)?.let { return error(400, id, Mcp.HEADER_MISMATCH, it) }
        headerMismatch(Mcp.HEADER_METHOD, method, headers)?.let { return error(400, id, Mcp.HEADER_MISMATCH, it) }
        if (meta[Mcp.META_CLIENT_CAPABILITIES] !is JsonObject) {
            return error(400, id, Mcp.INVALID_PARAMS, "params._meta must carry ${Mcp.META_CLIENT_CAPABILITIES}")
        }
        val caller = callerOf(meta[Mcp.META_CLIENT_INFO], headers)
        val result = when (method) {
            "server/discover" -> buildJsonObject {
                putJsonArray("supportedVersions") { Mcp.SUPPORTED.forEach { add(JsonPrimitive(it)) } }
                putJsonObject("capabilities") { putJsonObject("tools") {} }
                put("instructions", instructions)
                put("ttlMs", Mcp.LIST_TTL_MS)
                put("cacheScope", "private")
            }
            "tools/list" -> buildJsonObject {
                put("tools", toolList())
                put("ttlMs", Mcp.LIST_TTL_MS)
                put("cacheScope", "private")
            }
            "tools/call" -> {
                val name = (params["name"] as? JsonPrimitive)?.contentOrNull
                headerMismatch(Mcp.HEADER_NAME, name.orEmpty(), headers)?.let { return error(400, id, Mcp.HEADER_MISMATCH, it) }
                callTool(id, params, caller) { return it }
            }
            else -> return error(404, id, Mcp.METHOD_NOT_FOUND, "Unknown method: $method")
        }
        return ok(id, modernResult(result))
    }

    private suspend fun legacy(id: JsonElement, method: String, params: JsonObject, headers: Map<String, String>): McpReply {
        val header = headers[Mcp.HEADER_VERSION]
        if (method != "initialize" && header != null && header !in Mcp.LEGACY) {
            return if (header == Mcp.MODERN) error(400, id, Mcp.INVALID_PARAMS, "A $header request must carry params._meta with ${Mcp.META_VERSION} and ${Mcp.META_CLIENT_CAPABILITIES}")
            else error(400, id, Mcp.UNSUPPORTED_VERSION, "Unsupported protocol version: $header")
        }
        val result = when (method) {
            "initialize" -> {
                val asked = (params["protocolVersion"] as? JsonPrimitive)?.contentOrNull
                buildJsonObject {
                    put("protocolVersion", asked?.takeIf { it in Mcp.LEGACY } ?: Mcp.LEGACY.first())
                    putJsonObject("capabilities") { putJsonObject("tools") {} }
                    put("serverInfo", serverInfo())
                    put("instructions", instructions)
                }
            }
            "ping" -> JsonObject(emptyMap())
            "tools/list" -> buildJsonObject { put("tools", toolList()) }
            "tools/call" -> callTool(id, params, callerOf((params["_meta"] as? JsonObject)?.get(Mcp.META_CLIENT_INFO), headers)) { return it }
            else -> return error(200, id, Mcp.METHOD_NOT_FOUND, "Unknown method: $method")
        }
        return ok(id, result)
    }

    /** Runs the tool [params] name; an unknown tool returns through [fail], as a protocol error. */
    private suspend inline fun callTool(id: JsonElement, params: JsonObject, caller: McpCaller, fail: (McpReply) -> Nothing): JsonObject {
        val name = (params["name"] as? JsonPrimitive)?.takeIf { it.isString }?.content
            ?: fail(error(400, id, Mcp.INVALID_PARAMS, "tools/call needs a tool name"))
        val tool = tools().find { it.name == name } ?: fail(error(400, id, Mcp.INVALID_PARAMS, "Unknown tool: $name"))
        val arguments = when (val raw = params["arguments"]) {
            null, is JsonNull -> JsonObject(emptyMap())
            is JsonObject -> raw
            else -> fail(error(400, id, Mcp.INVALID_PARAMS, "arguments must be an object"))
        }
        val result = try {
            tool.call(arguments, caller)
        } catch (e: McpToolError) {
            McpToolResult(e.message.orEmpty(), isError = true)
        } catch (e: Exception) {
            if (e is CancellationException) throw e
            // Never the exception's own text: it may name an address or a path.
            McpToolResult("${tool.title} failed inside OmniTerm.", isError = true)
        }
        onCall(caller, tool.name, result)
        return buildJsonObject {
            putJsonArray("content") {
                add(buildJsonObject { put("type", "text"); put("text", result.text) })
            }
            result.structured?.let { put("structuredContent", it) }
            put("isError", result.isError)
        }
    }

    private suspend fun toolList(): JsonArray = buildJsonArray { tools().sortedBy { it.name }.forEach { add(it.describe()) } }

    private fun serverInfo(): JsonObject = buildJsonObject {
        put("name", serverName)
        put("title", serverTitle)
        put("version", serverVersion)
    }

    private fun modernResult(result: JsonObject): JsonObject = JsonObject(
        result + mapOf(
            "resultType" to JsonPrimitive("complete"),
            "_meta" to buildJsonObject { put(Mcp.META_SERVER_INFO, serverInfo()) },
        ),
    )

    private fun headerMismatch(header: String, expected: String, headers: Map<String, String>): String? {
        val sent = headers[header]
        return when {
            sent == null -> "Header mismatch: the $header header is missing"
            sent != expected -> "Header mismatch: $header header value '${sent.take(80)}' does not match body value '${expected.take(80)}'"
            else -> null
        }
    }

    /** The client's name from its clientInfo, else its User-Agent: a 2025 client names itself only in `initialize`. */
    private fun callerOf(info: JsonElement?, headers: Map<String, String>): McpCaller {
        val name = (info as? JsonObject)?.let {
            (it["title"] as? JsonPrimitive)?.contentOrNull ?: (it["name"] as? JsonPrimitive)?.contentOrNull
        } ?: headers["user-agent"]
        val clean = name.orEmpty().filter { !it.isISOControl() }.trim().take(Mcp.CLIENT_NAME_CHARS)
        return McpCaller(clean.ifEmpty { "Unnamed client" })
    }

    private fun ok(id: JsonElement, result: JsonObject) = McpReply(
        200,
        buildJsonObject {
            put("jsonrpc", "2.0")
            put("id", id)
            put("result", result)
        }.toString(),
    )

    private fun error(status: Int, id: JsonElement, code: Int, message: String, data: JsonObject? = null) = McpReply(
        status,
        buildJsonObject {
            put("jsonrpc", "2.0")
            put("id", id)
            putJsonObject("error") {
                put("code", code)
                put("message", message)
                data?.let { put("data", it) }
            }
        }.toString(),
    )
}
