package com.jetsetslow.omniterm.shared.network

internal data class WebDavEntry(
    val href: String,
    val directory: Boolean,
    val size: Long,
    val modified: String?,
)

/** Namespace-prefix tolerant parser for the small DAV property subset OmniTerm requests. */
internal fun parseWebDavMultistatus(xml: String): List<WebDavEntry> {
    val responses = Regex("(?is)<(?:[A-Za-z_][\\w.-]*:)?response(?:\\s[^>]*)?>(.*?)</(?:[A-Za-z_][\\w.-]*:)?response\\s*>")
    return responses.findAll(xml).mapNotNull { match ->
        val body = match.groupValues[1]
        val href = body.xmlText("href")?.decodeXmlEntities()?.trim().orEmpty()
        if (href.isEmpty()) return@mapNotNull null
        val directory = Regex("(?is)<(?:[A-Za-z_][\\w.-]*:)?collection(?:\\s[^>]*)?/?>").containsMatchIn(body)
        val size = body.xmlText("getcontentlength")?.trim()?.toLongOrNull() ?: 0L
        WebDavEntry(href, directory, size, body.xmlText("getlastmodified")?.decodeXmlEntities()?.trim())
    }.toList()
}

private fun String.xmlText(localName: String): String? =
    Regex("(?is)<(?:[A-Za-z_][\\w.-]*:)?$localName(?:\\s[^>]*)?>(.*?)</(?:[A-Za-z_][\\w.-]*:)?$localName\\s*>")
        .find(this)?.groupValues?.get(1)?.replace(Regex("(?s)<[^>]+>"), "")

private fun String.decodeXmlEntities(): String =
    replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("&quot;", "\"")
        .replace("&apos;", "'")
        .replace("&amp;", "&")
