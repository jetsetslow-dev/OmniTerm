package com.jetsetslow.omniterm.data

import com.jetsetslow.omniterm.data.tunnel.HostRoute
import com.jetsetslow.omniterm.data.tunnel.TunnelDns
import com.jetsetslow.omniterm.data.tunnel.TunnelHttpSocketFactory
import com.squareup.moshi.Moshi
import kotlinx.coroutines.Dispatchers
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
 * [ProxmoxTransport] on OkHttp, the only Proxmox file that uses an HTTP or TLS library. Over HTTPS
 * with the server's API token, trusting the phone's CAs or the one certificate whose fingerprint
 * the user trusted ([CertificateTrust]). [tunnelId] is the tunnel to use now (from
 * [HostRoute.tunnelNow]): then every connection goes through it, to
 * [ProxmoxServerEntity.tunnelHost] when that is set, and the phone looks nothing up itself. The
 * token goes only in the Authorization header, never in a URL or a log. No redirects.
 */
class OkHttpProxmoxTransport(private val server: ProxmoxServerEntity, tunnelId: Int?, base: OkHttpClient = SHARED) : ProxmoxTransport {
    private val origin: HttpUrl? = runCatching {
        HttpUrl.Builder().scheme("https").host(server.host.trim().removeSurrounding("[", "]")).port(server.port).build()
    }.getOrNull()
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

    override suspend fun call(method: ProxmoxTransport.Method, path: List<String>, query: Map<String, String>, form: Map<String, String>): Any? {
        val start = origin ?: throw ProxmoxException("${server.host} is not an address OmniTerm can connect to")
        val url = start.newBuilder()
            .addPathSegment("api2").addPathSegment("json")
            .apply { path.forEach { addPathSegment(it) } }
            .apply { query.forEach { (k, v) -> addQueryParameter(k, v) } }
            .build()
        val request = Request.Builder().url(url)
            .header("Accept", "application/json")
            .header("Authorization", "PVEAPIToken=${server.tokenId.trim()}=${server.tokenSecret.trim()}")
            .apply {
                when (method) {
                    ProxmoxTransport.Method.GET -> get()
                    ProxmoxTransport.Method.POST -> post(FormBody.Builder().apply { form.forEach { (k, v) -> add(k, v) } }.build())
                    ProxmoxTransport.Method.DELETE -> delete()
                }
            }
            .build()
        return withContext(Dispatchers.IO) {
            try {
                client.newCall(request).execute().use { response: Response ->
                    val body = response.body?.string().orEmpty()
                    val tree = runCatching { JSON.fromJson(body) }.getOrNull()
                    if (!response.isSuccessful) throw ProxmoxException(Proxmox.refusal(response.code, response.message, tree))
                    // Every Proxmox answer is an object with its result in "data".
                    if (tree !is Map<*, *>) throw ProxmoxException("${server.host}:${server.port} did not answer as Proxmox VE does")
                    tree["data"]
                }
            } catch (e: IOException) {
                CertificateTrust.untrustedIn(e)?.let { throw ProxmoxUntrusted(it.fingerprint, it.changed) }
                throw ProxmoxException("Could not reach ${server.host}:${server.port}: ${e.message ?: e.javaClass.simpleName}", e)
            }
        }
    }

    private companion object {
        const val DIRECT_CONNECT_SECONDS = 10L
        const val TUNNEL_CONNECT_SECONDS = 30L
        val SHARED = OkHttpClient()
        val JSON = Moshi.Builder().build().adapter(Any::class.java)
    }
}
