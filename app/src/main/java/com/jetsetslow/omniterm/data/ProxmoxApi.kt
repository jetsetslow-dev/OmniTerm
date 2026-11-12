package com.jetsetslow.omniterm.data

import com.jetsetslow.omniterm.data.KubeApi.Companion.at
import com.jetsetslow.omniterm.data.KubeApi.Companion.list
import com.jetsetslow.omniterm.data.KubeApi.Companion.text
import com.jetsetslow.omniterm.data.tunnel.HostRoute
import com.jetsetslow.omniterm.data.tunnel.TunnelDns
import com.jetsetslow.omniterm.data.tunnel.TunnelHttpSocketFactory
import com.squareup.moshi.Moshi
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext
import okhttp3.FormBody
import okhttp3.HttpUrl
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import java.io.IOException
import java.util.concurrent.TimeUnit
import javax.net.ssl.SSLContext

/**
 * What OmniTerm reads from and does on a Proxmox VE server, from the documented API
 * (https://pve.proxmox.com/pve-docs/api-viewer/): nodes, guests (VMs and containers), their power
 * and snapshots, and the backup (vzdump) tasks.
 */
object Proxmox {
    data class Node(val name: String, val online: Boolean, val cpu: Float?, val memUsed: Long?, val memTotal: Long?, val uptime: Long?)

    /** A VM ([type] `qemu`) or container (`lxc`). */
    data class Guest(
        val node: String,
        val vmid: Int,
        val type: String,
        val name: String,
        val status: String,
        val cpu: Float?,
        val cpus: Int?,
        val memUsed: Long?,
        val memTotal: Long?,
        val uptime: Long?,
        val template: Boolean,
    ) {
        val key get() = "$type/$vmid"
        val running get() = status == "running"
        val kindLabel get() = if (type == "lxc") "CT" else "VM"
        /** How the guest is named on screen and in every confirmation: "VM 100 (web)". */
        val label get() = "$kindLabel $vmid" + if (name.isNotBlank()) " ($name)" else ""
    }

    data class Snapshot(val name: String, val description: String, val time: Long?, val parent: String)

    /** A task: [status] is "OK", a warning or the error, or empty while it runs. */
    data class Task(val upid: String, val node: String, val type: String, val id: String, val user: String, val start: Long?, val end: Long?, val status: String) {
        val running get() = end == null && status.isEmpty()
        val ok get() = status == "OK"
    }

    data class Overview(val version: String, val nodes: List<Node>, val guests: List<Guest>, val backups: List<Task>)

    /** The power actions, as the API names them. */
    enum class Power(val action: String) { START("start"), SHUTDOWN("shutdown"), REBOOT("reboot"), STOP("stop") }

    const val DEFAULT_PORT = 8006
    const val BACKUP_TASKS = 10
    private val TOKEN_ID = Regex("""^[^\s@!:=]+@[^\s@!:=]+![A-Za-z][A-Za-z0-9._-]*$""")
    private val SNAPSHOT_NAME = Regex("""^[A-Za-z][A-Za-z0-9_-]{1,39}$""")

    /** Why [server] cannot be saved as it is, or null. */
    fun problem(server: ProxmoxServerEntity): String? = when {
        server.name.isBlank() -> "Enter a name"
        server.host.isBlank() || server.host.any { it.isWhitespace() || it == '/' } || !hostParses(server.host) ->
            "Enter the server's address, such as 192.168.1.10 or pve.lan"
        server.port !in 1..65535 -> "The port must be between 1 and 65535"
        !TOKEN_ID.matches(server.tokenId.trim()) -> "The token ID looks like user@pam!name, as Datacenter → Permissions → API Tokens shows it"
        server.tokenSecret.isBlank() -> "Enter the token's secret"
        else -> null
    }

    private fun hostParses(host: String) =
        runCatching { HttpUrl.Builder().scheme("https").host(host.trim().removeSurrounding("[", "]")) }.isSuccess

    /** Why [name] is not a snapshot name Proxmox takes, or null. */
    fun snapshotNameProblem(name: String): String? = when {
        name == "current" -> "\"current\" is reserved by Proxmox"
        !SNAPSHOT_NAME.matches(name) -> "2 to 40 letters, digits, - or _, starting with a letter"
        else -> null
    }

    internal fun nodes(data: Any?): List<Node> = data.list().map { n ->
        Node(
            name = n.text("node"),
            online = n.text("status") == "online",
            cpu = n.float("cpu"),
            memUsed = n.long("mem"),
            memTotal = n.long("maxmem"),
            uptime = n.long("uptime"),
        )
    }.filter { it.name.isNotEmpty() }.sortedBy { it.name }

    internal fun guests(data: Any?): List<Guest> = data.list().mapNotNull { g ->
        val type = g.text("type").takeIf { it == "qemu" || it == "lxc" } ?: return@mapNotNull null
        val vmid = g.text("vmid").toIntOrNull() ?: return@mapNotNull null
        Guest(
            node = g.text("node"),
            vmid = vmid,
            type = type,
            name = g.text("name"),
            status = g.text("status"),
            cpu = g.float("cpu"),
            cpus = g.long("maxcpu")?.toInt(),
            memUsed = g.long("mem"),
            memTotal = g.long("maxmem"),
            uptime = g.long("uptime"),
            template = g.text("template") == "1",
        )
    }.sortedBy { it.vmid }

    /** A guest's snapshots, newest first, without "current" (where the guest is now). */
    internal fun snapshots(data: Any?): List<Snapshot> = data.list().map { s ->
        Snapshot(s.text("name"), s.text("description").trim(), s.long("snaptime"), s.text("parent"))
    }.filter { it.name.isNotEmpty() && it.name != "current" }.sortedByDescending { it.time ?: 0 }

    internal fun tasks(data: Any?): List<Task> = data.list().map { t ->
        Task(t.text("upid"), t.text("node"), t.text("type"), t.text("id"), t.text("user"), t.long("starttime"), t.long("endtime"), t.text("status"))
    }.filter { it.upid.isNotEmpty() }

    private fun Any?.long(key: String): Long? = (at(key) as? Number)?.toLong() ?: text(key).toLongOrNull()
    private fun Any?.float(key: String): Float? = (at(key) as? Number)?.toFloat() ?: text(key).toFloatOrNull()

    /**
     * Why the server refused, in words. Proxmox puts its reason in the HTTP status line ("Permission
     * check failed (/vms/100, VM.PowerMgmt)"), and parameter errors in the body's "errors".
     */
    internal fun refusal(code: Int, reason: String, body: String): String {
        val errors = runCatching { json.fromJson(body) }.getOrNull().at("errors") as? Map<*, *>
        val detail = errors?.entries?.joinToString("; ") { (k, v) -> "$k: ${v.toString().trim()}" }.orEmpty()
        return when (code) {
            401 -> "Proxmox refused the token: check its ID and secret, and that it has not expired"
            403 -> "The token may not do this" + (reason.takeIf { it.isNotBlank() && it != "Forbidden" }?.let { ": $it" } ?: "") +
                ". A token with privilege separation needs its own permissions"
            else -> "Proxmox answered $code" + (reason.takeIf { it.isNotBlank() }?.let { " $it" } ?: "") +
                (detail.takeIf { it.isNotEmpty() }?.let { " ($it)" } ?: "")
        }
    }

    internal val json = Moshi.Builder().build().adapter(Any::class.java)
}

/** A refusal or failure the user can read. */
class ProxmoxException(message: String, cause: Throwable? = null) : IOException(message, cause)

/**
 * One Proxmox VE server's API, over HTTPS with its API token. [tunnelId] is the tunnel to use now
 * (from [HostRoute.tunnelNow]): then every connection goes through it, to [ProxmoxServerEntity.tunnelHost]
 * when that is set, and the phone looks nothing up itself. The token goes only in the
 * Authorization header, never in a URL or a log.
 */
class ProxmoxApi(private val server: ProxmoxServerEntity, tunnelId: Int?, base: OkHttpClient = SHARED) {
    private val origin: HttpUrl = HttpUrl.Builder().scheme("https").host(server.host.trim().removeSurrounding("[", "]")).port(server.port).build()
    private val trust = CertificateTrust.Pinned(server.fingerprint)

    private val client: OkHttpClient = run {
        val context = SSLContext.getInstance("TLS").apply { init(null, arrayOf(trust), null) }
        base.newBuilder()
            .sslSocketFactory(context.socketFactory, trust)
            .hostnameVerifier(trust.hostnameVerifier())
            .followRedirects(false)
            .followSslRedirects(false)
            // Through a tunnel the first connection may wait for the tunnel to start, and a Tailscale
            // one to sign in and find its peer: 15 s on the device suite's Headscale fixture.
            .connectTimeout(if (tunnelId != null) TUNNEL_CONNECT_SECONDS else DIRECT_CONNECT_SECONDS, TimeUnit.SECONDS)
            .readTimeout(30, TimeUnit.SECONDS)
            .apply {
                if (tunnelId != null) {
                    socketFactory(TunnelHttpSocketFactory(tunnelId, HostRoute.rename(server.host.trim(), server.tunnelHost)))
                    dns(TunnelDns)
                }
            }
            .build()
    }

    private fun url(vararg segments: String, query: Map<String, String> = emptyMap()): HttpUrl = origin.newBuilder()
        .addPathSegment("api2").addPathSegment("json")
        .apply { segments.forEach { addPathSegment(it) } }
        .apply { query.forEach { (k, v) -> addQueryParameter(k, v) } }
        .build()

    private fun request(url: HttpUrl) = Request.Builder().url(url)
        .header("Accept", "application/json")
        .header("Authorization", "PVEAPIToken=${server.tokenId.trim()}=${server.tokenSecret.trim()}")

    /** The `data` of [request]'s answer. */
    private suspend fun call(request: Request): Any? = withContext(Dispatchers.IO) {
        try {
            client.newCall(request).execute().use { response: Response ->
                val body = response.body?.string().orEmpty()
                if (!response.isSuccessful) throw ProxmoxException(Proxmox.refusal(response.code, response.message, body))
                Proxmox.json.fromJson(body).at("data")
            }
        } catch (e: ProxmoxException) {
            throw e
        } catch (e: IOException) {
            CertificateTrust.untrustedIn(e)?.let { throw it.asIOException() }
            throw ProxmoxException("Could not reach ${server.host}:${server.port}: ${e.message ?: e.javaClass.simpleName}", e)
        }
    }

    private suspend fun get(vararg segments: String, query: Map<String, String> = emptyMap()) = call(request(url(*segments, query = query)).get().build())

    private suspend fun post(vararg segments: String, form: Map<String, String> = emptyMap()) =
        call(request(url(*segments)).post(FormBody.Builder().apply { form.forEach { (k, v) -> add(k, v) } }.build()).build())

    private suspend fun delete(vararg segments: String) = call(request(url(*segments)).delete().build())

    /** The version, nodes, guests and the newest backup tasks of the online nodes. */
    suspend fun overview(): Proxmox.Overview {
        val version = get("version").text("version")
        val nodes = Proxmox.nodes(get("nodes"))
        val guests = Proxmox.guests(get("cluster", "resources", query = mapOf("type" to "vm")))
        val backups = nodes.filter { it.online }.flatMap { node ->
            Proxmox.tasks(get("nodes", node.name, "tasks", query = mapOf("typefilter" to "vzdump", "limit" to Proxmox.BACKUP_TASKS.toString())))
        }.sortedByDescending { it.start ?: 0 }.take(Proxmox.BACKUP_TASKS)
        return Proxmox.Overview(version, nodes, guests, backups)
    }

    suspend fun snapshots(guest: Proxmox.Guest): List<Proxmox.Snapshot> =
        Proxmox.snapshots(get("nodes", guest.node, guest.type, guest.vmid.toString(), "snapshot"))

    /** Runs [power] on [guest] and waits for its task; returns how the task ended. */
    suspend fun power(guest: Proxmox.Guest, power: Proxmox.Power): String =
        finish(guest.node, post("nodes", guest.node, guest.type, guest.vmid.toString(), "status", power.action))

    suspend fun createSnapshot(guest: Proxmox.Guest, name: String, description: String): String {
        Proxmox.snapshotNameProblem(name)?.let { throw ProxmoxException(it) }
        val form = buildMap { put("snapname", name); if (description.isNotBlank()) put("description", description.trim()) }
        return finish(guest.node, post("nodes", guest.node, guest.type, guest.vmid.toString(), "snapshot", form = form))
    }

    suspend fun rollback(guest: Proxmox.Guest, snapshot: String): String =
        finish(guest.node, post("nodes", guest.node, guest.type, guest.vmid.toString(), "snapshot", snapshot, "rollback"))

    suspend fun deleteSnapshot(guest: Proxmox.Guest, snapshot: String): String =
        finish(guest.node, delete("nodes", guest.node, guest.type, guest.vmid.toString(), "snapshot", snapshot))

    /**
     * Waits for the task [upid] an action started, up to [TASK_WAIT_MS]; "OK", or why it failed
     * (thrown), or that it still runs.
     */
    private suspend fun finish(node: String, upid: Any?): String {
        val id = upid?.toString().orEmpty().takeIf { it.startsWith("UPID:") } ?: return "OK"
        val deadline = System.currentTimeMillis() + TASK_WAIT_MS
        while (System.currentTimeMillis() < deadline) {
            val status = get("nodes", node, "tasks", id, "status")
            if (status.text("status") == "stopped") {
                val exit = status.text("exitstatus")
                if (exit == "OK" || exit.startsWith("WARNINGS")) return exit
                throw ProxmoxException("The task failed: $exit")
            }
            delay(TASK_POLL_MS)
        }
        return "still running on the server"
    }

    companion object {
        private const val DIRECT_CONNECT_SECONDS = 10L
        private const val TUNNEL_CONNECT_SECONDS = 30L
        private const val TASK_WAIT_MS = 120_000L
        private const val TASK_POLL_MS = 1_000L
        private val SHARED = OkHttpClient()

        private fun CertificateTrust.Untrusted.asIOException() = UntrustedServer(this)
    }

    /** The server's certificate needs the user's trust: [untrusted] has its fingerprint. */
    class UntrustedServer(val untrusted: CertificateTrust.Untrusted) : IOException(untrusted.message, untrusted)
}
