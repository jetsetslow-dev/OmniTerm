package com.jetsetslow.omniterm.data

/**
 * A host's tags ([ServerEntity.tags]): short labels such as `db` or `prod`, any number per host, so
 * Fleet can run on every host with a tag, or with several. Stored as "db, prod". Tags compare
 * without regard to case, and the first spelling the user typed is kept.
 *
 * Idea credit: Termix Fleets' tag rules (docs.termix.site/plugins/fleets).
 */
object HostTags {
    const val MAX_TAGS = 20
    const val MAX_LENGTH = 32

    /** The tags in [raw] as typed: split at commas, trimmed, blanks and repeats dropped, each cut to [MAX_LENGTH]. */
    fun parse(raw: String): List<String> =
        raw.split(',')
            .map { it.trim().take(MAX_LENGTH).trim() }
            .filter { it.isNotEmpty() }
            .distinctBy { it.lowercase() }
            .take(MAX_TAGS)

    /** [tags] as a host stores them: normalised as [parse] does. */
    fun format(tags: List<String>): String = parse(tags.joinToString(",")).joinToString(", ")

    /** Whether [host] carries [tag]. */
    fun has(host: ServerEntity, tag: String): Boolean = parse(host.tags).any { it.equals(tag, ignoreCase = true) }

    /** Every tag on [hosts], once each, sorted, in the first spelling found. */
    fun all(hosts: List<ServerEntity>): List<String> =
        hosts.flatMap { parse(it.tags) }.distinctBy { it.lowercase() }.sortedBy { it.lowercase() }
}
