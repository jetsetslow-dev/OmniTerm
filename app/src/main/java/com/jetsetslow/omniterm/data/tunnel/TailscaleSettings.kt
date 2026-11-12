package com.jetsetslow.omniterm.data.tunnel

import org.json.JSONObject

/**
 * A Tailscale tunnel's settings, stored as its configuration (TunnelEntity.config, encrypted) in
 * the JSON the Go library reads (tunnel/omnitunnel/tailscale.go). [controlUrl] is empty for
 * Tailscale's own coordination server, or a Headscale server's address; [authKey] is empty to sign
 * in through the page the tunnel gives instead.
 */
data class TailscaleSettings(
    val controlUrl: String = "",
    val authKey: String = "",
    val hostname: String = "",
) {
    fun toConfig(): String = JSONObject()
        .put("controlUrl", controlUrl.trim())
        .put("authKey", authKey.trim())
        .put("hostname", hostname.trim())
        .toString()

    /**
     * Whether the control server is reached over plain HTTP across a network: the tunnel then
     * fetches the server's key unencrypted, so anyone on the way could pose as the server. A server
     * on this phone itself (loopback) is no such risk.
     */
    fun plainHttp(): Boolean {
        val url = controlUrl.trim()
        if (!url.startsWith("http://", ignoreCase = true)) return false
        val host = runCatching { java.net.URI(url).host }.getOrNull()?.trim('[', ']')?.lowercase() ?: return true
        return !(host == "localhost" || host == "::1" || host.startsWith("127."))
    }

    /** The same tailnet as [other]: one control server, compared without a trailing slash or case. */
    fun sameServerAs(other: TailscaleSettings): Boolean = server(controlUrl) == server(other.controlUrl)

    companion object {
        /** The settings in [config], or null when it is not a Tailscale tunnel's. */
        fun parse(config: String): TailscaleSettings? = runCatching {
            val o = JSONObject(config)
            TailscaleSettings(o.optString("controlUrl"), o.optString("authKey"), o.optString("hostname"))
        }.getOrNull()

        /** A device name the tailnet takes from a phone's model: letters, digits and hyphens. */
        fun deviceName(model: String): String {
            val base = model.lowercase().replace(Regex("[^a-z0-9]+"), "-").trim('-').take(50).trim('-')
            return if (base.isEmpty()) "omniterm" else "omniterm-$base"
        }

        private fun server(url: String) = url.trim().trimEnd('/').lowercase()
    }
}
