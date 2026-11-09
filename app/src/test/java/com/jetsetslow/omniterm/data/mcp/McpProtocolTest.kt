package com.jetsetslow.omniterm.data.mcp

import com.google.common.truth.Truth.assertThat
import com.google.common.truth.Truth.assertWithMessage
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Test

/** The JSON-RPC side of the MCP server: both protocol eras, their errors, and tool calls. */
class McpProtocolTest {
    private val calls = mutableListOf<Triple<String, String, Boolean>>()

    private val echo = McpTool(
        name = "echo", title = "Echo", description = "Says it back",
        inputSchema = Json.parseToJsonElement("""{"type":"object"}""").jsonObject,
        readOnly = true, destructive = false, idempotent = true, openWorld = false,
    ) { args, _ -> McpToolResult("said " + (args["text"]?.jsonPrimitive?.content ?: "")) }

    private val refuses = McpTool(
        name = "refuses", title = "Refuses", description = "Always says no",
        inputSchema = Json.parseToJsonElement("""{"type":"object"}""").jsonObject,
        readOnly = false, destructive = true, idempotent = false, openWorld = true,
    ) { _, _ -> throw McpToolError("not today") }

    private val crashes = McpTool(
        name = "crashes", title = "Crashes", description = "Fails inside",
        inputSchema = Json.parseToJsonElement("""{"type":"object"}""").jsonObject,
        readOnly = true, destructive = false, idempotent = true, openWorld = false,
    ) { _, _ -> throw IllegalStateException("connect to 10.0.0.5:22 failed") }

    private val handler = McpHandler(
        serverName = "omniterm", serverTitle = "OmniTerm", serverVersion = "9.9",
        instructions = "Be careful",
        tools = { listOf(refuses, echo, crashes) },
        onCall = { caller, tool, result -> calls += Triple(caller.clientName, tool, result.isError) },
    )

    private fun meta(extra: String = "") =
        """"_meta":{"${Mcp.META_VERSION}":"${Mcp.MODERN}","${Mcp.META_CLIENT_CAPABILITIES}":{},"${Mcp.META_CLIENT_INFO}":{"name":"test-client","version":"1"}$extra}"""

    private fun modernHeaders(method: String, name: String? = null) = buildMap {
        put(Mcp.HEADER_VERSION, Mcp.MODERN)
        put(Mcp.HEADER_METHOD, method)
        name?.let { put(Mcp.HEADER_NAME, it) }
    }

    private fun send(body: String, headers: Map<String, String> = emptyMap()): Pair<Int, JsonObject?> = runBlocking {
        val reply = handler.handle(body, headers)
        reply.status to reply.body?.let { Json.parseToJsonElement(it).jsonObject }
    }

    private fun errorCode(body: JsonObject?) = body!!["error"]!!.jsonObject["code"]!!.jsonPrimitive.int

    @Test
    fun aModernClientDiscoversTheServerWithoutAHandshake() {
        val (status, body) = send(
            """{"jsonrpc":"2.0","id":1,"method":"server/discover","params":{${meta()}}}""",
            modernHeaders("server/discover"),
        )
        assertThat(status).isEqualTo(200)
        val result = body!!["result"]!!.jsonObject
        assertThat(result["resultType"]!!.jsonPrimitive.content).isEqualTo("complete")
        assertThat(result["supportedVersions"]!!.jsonArray.map { it.jsonPrimitive.content }).containsExactlyElementsIn(Mcp.SUPPORTED)
        assertThat(result["capabilities"]!!.jsonObject.keys).containsExactly("tools")
        assertThat(result["cacheScope"]!!.jsonPrimitive.content).isEqualTo("private")
        assertThat(result["ttlMs"]!!.jsonPrimitive.int).isGreaterThan(0)
        assertThat(result["instructions"]!!.jsonPrimitive.content).isEqualTo("Be careful")
        val info = result["_meta"]!!.jsonObject[Mcp.META_SERVER_INFO]!!.jsonObject
        assertThat(info["name"]!!.jsonPrimitive.content).isEqualTo("omniterm")
        assertThat(info["version"]!!.jsonPrimitive.content).isEqualTo("9.9")
    }

    @Test
    fun aModernToolListIsSortedAndCarriesHintsAndCaching() {
        val (status, body) = send(
            """{"jsonrpc":"2.0","id":"a","method":"tools/list","params":{${meta()}}}""",
            modernHeaders("tools/list"),
        )
        assertThat(status).isEqualTo(200)
        val result = body!!["result"]!!.jsonObject
        assertThat(body["id"]!!.jsonPrimitive.content).isEqualTo("a")
        assertThat(result["resultType"]!!.jsonPrimitive.content).isEqualTo("complete")
        assertThat(result["cacheScope"]!!.jsonPrimitive.content).isEqualTo("private")
        val tools = result["tools"]!!.jsonArray.map { it.jsonObject }
        assertThat(tools.map { it["name"]!!.jsonPrimitive.content }).containsExactly("crashes", "echo", "refuses").inOrder()
        val hints = tools.last()["annotations"]!!.jsonObject
        assertThat(hints["readOnlyHint"]!!.jsonPrimitive.boolean).isFalse()
        assertThat(hints["destructiveHint"]!!.jsonPrimitive.boolean).isTrue()
        assertThat(hints["openWorldHint"]!!.jsonPrimitive.boolean).isTrue()
        assertThat(tools[1]["annotations"]!!.jsonObject["readOnlyHint"]!!.jsonPrimitive.boolean).isTrue()
    }

    @Test
    fun aModernToolCallReturnsItsResultAndIsRecorded() {
        val (status, body) = send(
            """{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"echo","arguments":{"text":"hi"},${meta()}}}""",
            modernHeaders("tools/call", "echo"),
        )
        assertThat(status).isEqualTo(200)
        val result = body!!["result"]!!.jsonObject
        assertThat(result["resultType"]!!.jsonPrimitive.content).isEqualTo("complete")
        assertThat(result["isError"]!!.jsonPrimitive.boolean).isFalse()
        assertThat(result["content"]!!.jsonArray.single().jsonObject["text"]!!.jsonPrimitive.content).isEqualTo("said hi")
        assertThat(calls).containsExactly(Triple("test-client", "echo", false))
    }

    @Test
    fun aToolsRefusalIsAnErrorResultTheModelCanReadAndAnInternalFailureLeaksNothing() {
        val (_, refused) = send(
            """{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"refuses",${meta()}}}""",
            modernHeaders("tools/call", "refuses"),
        )
        val r = refused!!["result"]!!.jsonObject
        assertThat(r["isError"]!!.jsonPrimitive.boolean).isTrue()
        assertThat(r["content"]!!.jsonArray.single().jsonObject["text"]!!.jsonPrimitive.content).isEqualTo("not today")

        val (_, crashed) = send(
            """{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"crashes",${meta()}}}""",
            modernHeaders("tools/call", "crashes"),
        )
        val text = crashed.toString()
        assertThat(crashed!!["result"]!!.jsonObject["isError"]!!.jsonPrimitive.boolean).isTrue()
        assertWithMessage("an exception's own text may name an address").that(text).doesNotContain("10.0.0.5")
        assertThat(calls.map { it.third }).containsExactly(true, true)
    }

    @Test
    fun theModernHeadersMustMatchTheBody() {
        val body = """{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"echo",${meta()}}}"""
        listOf(
            modernHeaders("tools/call", "echo") - Mcp.HEADER_VERSION,
            modernHeaders("tools/call", "echo") - Mcp.HEADER_METHOD,
            modernHeaders("tools/call"),
            modernHeaders("tools/list", "echo"),
            modernHeaders("tools/call", "refuses"),
            modernHeaders("tools/call", "echo") + (Mcp.HEADER_VERSION to "2025-11-25"),
        ).forEach { headers ->
            val (status, reply) = send(body, headers)
            assertWithMessage(headers.toString()).that(status).isEqualTo(400)
            assertWithMessage(headers.toString()).that(errorCode(reply)).isEqualTo(Mcp.HEADER_MISMATCH)
        }
        assertWithMessage("a mismatched call runs nothing").that(calls).isEmpty()
    }

    @Test
    fun anUnsupportedModernVersionNamesTheSupportedOnes() {
        val (status, body) = send(
            """{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{"_meta":{"${Mcp.META_VERSION}":"2099-01-01","${Mcp.META_CLIENT_CAPABILITIES}":{}}}}""",
            modernHeaders("tools/list") + (Mcp.HEADER_VERSION to "2099-01-01"),
        )
        assertThat(status).isEqualTo(400)
        assertThat(errorCode(body)).isEqualTo(Mcp.UNSUPPORTED_VERSION)
        val data = body!!["error"]!!.jsonObject["data"]!!.jsonObject
        assertThat(data["requested"]!!.jsonPrimitive.content).isEqualTo("2099-01-01")
        assertThat(data["supported"]!!.jsonArray.map { it.jsonPrimitive.content }).contains(Mcp.MODERN)
    }

    @Test
    fun aModernRequestWithoutClientCapabilitiesIsInvalid() {
        val (status, body) = send(
            """{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{"_meta":{"${Mcp.META_VERSION}":"${Mcp.MODERN}"}}}""",
            modernHeaders("tools/list"),
        )
        assertThat(status).isEqualTo(400)
        assertThat(errorCode(body)).isEqualTo(Mcp.INVALID_PARAMS)
    }

    @Test
    fun aModernRequestNamingTheModernVersionOnlyInTheHeaderIsInvalid() {
        val (status, body) = send("""{"jsonrpc":"2.0","id":1,"method":"tools/list"}""", modernHeaders("tools/list"))
        assertThat(status).isEqualTo(400)
        assertThat(errorCode(body)).isEqualTo(Mcp.INVALID_PARAMS)
    }

    @Test
    fun unknownMethodsAndToolsAreProtocolErrors() {
        val (status, body) = send(
            """{"jsonrpc":"2.0","id":1,"method":"resources/list","params":{${meta()}}}""",
            modernHeaders("resources/list"),
        )
        assertThat(status).isEqualTo(404)
        assertThat(errorCode(body)).isEqualTo(Mcp.METHOD_NOT_FOUND)

        val (toolStatus, tool) = send(
            """{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"rm_rf",${meta()}}}""",
            modernHeaders("tools/call", "rm_rf"),
        )
        assertThat(toolStatus).isEqualTo(400)
        assertThat(errorCode(tool)).isEqualTo(Mcp.INVALID_PARAMS)
        assertThat(tool!!["error"]!!.jsonObject["message"]!!.jsonPrimitive.content).isEqualTo("Unknown tool: rm_rf")
    }

    @Test
    fun aLegacyClientInitializesThenListsAndCalls() {
        Mcp.LEGACY.forEach { version ->
            val (status, body) = send(
                """{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"$version","capabilities":{},"clientInfo":{"name":"old","version":"1"}}}""",
            )
            assertThat(status).isEqualTo(200)
            val result = body!!["result"]!!.jsonObject
            assertWithMessage(version).that(result["protocolVersion"]!!.jsonPrimitive.content).isEqualTo(version)
            assertThat(result["capabilities"]!!.jsonObject.keys).containsExactly("tools")
            assertThat(result["serverInfo"]!!.jsonObject["name"]!!.jsonPrimitive.content).isEqualTo("omniterm")
            assertWithMessage("no 2026 fields in a 2025 answer").that(result.keys).doesNotContain("resultType")
        }
        val (_, unknown) = send("""{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2024-11-05"}}""")
        assertWithMessage("an older version gets the newest 2025 one").that(unknown!!["result"]!!.jsonObject["protocolVersion"]!!.jsonPrimitive.content)
            .isEqualTo(Mcp.LEGACY.first())

        assertThat(send("""{"jsonrpc":"2.0","method":"notifications/initialized"}""", mapOf(Mcp.HEADER_VERSION to "2025-06-18")).first).isEqualTo(202)
        val (listStatus, list) = send("""{"jsonrpc":"2.0","id":1,"method":"tools/list"}""", mapOf(Mcp.HEADER_VERSION to "2025-06-18"))
        assertThat(listStatus).isEqualTo(200)
        assertThat(list!!["result"]!!.jsonObject["tools"]!!.jsonArray).hasSize(3)
        val (_, noHeader) = send("""{"jsonrpc":"2.0","id":2,"method":"ping"}""")
        assertWithMessage("a 2025-03-26 client sends no version header").that(noHeader!!["result"]!!.jsonObject).isEmpty()

        val (_, call) = send(
            """{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"echo","arguments":{"text":"x"}}}""",
            mapOf(Mcp.HEADER_VERSION to "2025-11-25", "user-agent" to "claude-code/2.1"),
        )
        assertThat(call!!["result"]!!.jsonObject["content"]!!.jsonArray.single().jsonObject["text"]!!.jsonPrimitive.content).isEqualTo("said x")
        assertWithMessage("a 2025 client is named by its User-Agent").that(calls.single().first).isEqualTo("claude-code/2.1")

        val (badStatus, bad) = send("""{"jsonrpc":"2.0","id":4,"method":"tools/list"}""", mapOf(Mcp.HEADER_VERSION to "2024-01-01"))
        assertThat(badStatus).isEqualTo(400)
        assertThat(errorCode(bad)).isEqualTo(Mcp.UNSUPPORTED_VERSION)
    }

    @Test
    fun malformedBodiesBatchesAndNotificationsAreHandled() {
        val (parseStatus, parse) = send("{not json")
        assertThat(parseStatus).isEqualTo(400)
        assertThat(errorCode(parse)).isEqualTo(Mcp.PARSE_ERROR)

        val (batchStatus, batch) = send("""[{"jsonrpc":"2.0","id":1,"method":"ping"}]""")
        assertThat(batchStatus).isEqualTo(400)
        assertThat(errorCode(batch)).isEqualTo(Mcp.INVALID_REQUEST)

        assertThat(send("""{"jsonrpc":"1.0","id":1,"method":"ping"}""").first).isEqualTo(400)
        assertThat(send("""{"jsonrpc":"2.0","id":{"x":1},"method":"ping"}""").first).isEqualTo(400)
        assertThat(send("""{"jsonrpc":"2.0","method":"tools/call","params":{"name":"echo"}}""").first)
            .isEqualTo(202)
        assertWithMessage("a notification runs no tool").that(calls).isEmpty()

        val (argsStatus, args) = send(
            """{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"echo","arguments":[1]}}""",
        )
        assertThat(argsStatus).isEqualTo(400)
        assertThat(errorCode(args)).isEqualTo(Mcp.INVALID_PARAMS)
    }

    @Test
    fun theClientNameKeptIsShortAndPrintable() {
        send(
            """{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"echo","_meta":{"${Mcp.META_VERSION}":"${Mcp.MODERN}","${Mcp.META_CLIENT_CAPABILITIES}":{},"${Mcp.META_CLIENT_INFO}":{"name":"${"x".repeat(200)}\n\u0007"}}}}""",
            modernHeaders("tools/call", "echo"),
        )
        assertThat(calls.single().first).isEqualTo("x".repeat(Mcp.CLIENT_NAME_CHARS))
    }
}
