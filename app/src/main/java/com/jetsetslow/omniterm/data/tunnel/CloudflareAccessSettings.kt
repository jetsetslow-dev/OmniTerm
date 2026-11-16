package com.jetsetslow.omniterm.data.tunnel

import org.json.JSONObject

/** Encrypted in TunnelEntity.config. Neither token field is loaded back into the editor. */
data class CloudflareAccessSettings(val hostname: String, val clientId: String, val clientSecret: String) {
    fun toConfig(): String = JSONObject().put("hostname", hostname.trim().lowercase())
        .put("clientId", clientId).put("clientSecret", clientSecret).toString()

    /** Blank fields keep the saved values; an edit never needs to reveal either credential. */
    fun keepingToken(before: CloudflareAccessSettings?): CloudflareAccessSettings = copy(
        clientId = clientId.ifEmpty { before?.clientId.orEmpty() },
        clientSecret = clientSecret.ifEmpty { before?.clientSecret.orEmpty() },
    )

    fun forEditor(): CloudflareAccessSettings = copy(clientId = "", clientSecret = "")
    override fun toString(): String = "CloudflareAccessSettings(token=redacted)"

    companion object {
        fun parse(config: String): CloudflareAccessSettings? = runCatching {
            val o = JSONObject(config)
            CloudflareAccessSettings(o.getString("hostname"), o.getString("clientId"), o.getString("clientSecret"))
        }.getOrNull()
    }
}
