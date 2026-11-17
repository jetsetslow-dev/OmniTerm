package com.jetsetslow.omniterm.data.tunnel

/**
 * The Wi-Fi networks a tunnel is not needed on. On one of them the tunnel's hosts dial their own
 * address; on any other network, or when the phone cannot tell which Wi-Fi it is on, they go
 * through the tunnel as always. It is a rule the user sets, never a fallback: nothing here looks
 * at whether the tunnel or the host answers.
 *
 * Names are kept one per line, spelled as the network spells them: a Wi-Fi name is case-sensitive
 * and at most [MAX_NAME_BYTES] bytes.
 */
object TunnelNetworks {
    const val MAX_NAMES = 10
    const val MAX_NAME_BYTES = 32

    /** The names in a tunnel's stored list. */
    fun names(stored: String): List<String> = stored.split('\n').filter { it.isNotEmpty() }

    /** [names] as they are stored: none empty, too long or twice, and [MAX_NAMES] at most. */
    fun stored(names: List<String>): String =
        names.map { name -> name.filter { it != '\n' && it != '\r' } }
            .filter { it.isNotEmpty() && !tooLong(it) }
            .distinct()
            .take(MAX_NAMES)
            .joinToString("\n")

    fun tooLong(name: String): Boolean = name.toByteArray(Charsets.UTF_8).size > MAX_NAME_BYTES

    /**
     * Whether the hosts of a tunnel with this [stored] list dial directly on Wi-Fi [wifi]. A null
     * [wifi] is "not on Wi-Fi, or Android did not say which": never direct.
     */
    fun goesDirect(stored: String, wifi: String?): Boolean = wifi != null && wifi in names(stored)
}

/**
 * Remembers each Wi-Fi connection's name once Android has given it. Android gives the name only
 * with the location permission and while the app is on screen; a background check on the same
 * connection gets it blanked, and still has to know where the phone is. Each time the phone joins
 * a Wi-Fi, Android counts a new connection, so a name is never carried over to another network,
 * and the count starts again with each start of the phone ([Seen.boot]).
 */
internal class WifiMemory(seen: Seen? = null) {
    data class Seen(val boot: Int, val connection: Long, val name: String)

    var seen: Seen? = seen
        private set

    /** The name of Wi-Fi [connection]: as [reported] now, or as it was when Android last gave it. */
    fun name(boot: Int, connection: Long, reported: String?): String? {
        val name = clean(reported)
        if (name != null) {
            seen = Seen(boot, connection, name)
            return name
        }
        return seen?.takeIf { it.boot == boot && it.connection == connection }?.name
    }

    companion object {
        /** What Android reports when it withholds the name (WifiManager.UNKNOWN_SSID). */
        const val WITHHELD = "<unknown ssid>"

        /**
         * A name as the user sees it. Android puts a name that is text in double quotes, and gives
         * one that is not as bare hex digits, which stay as they are.
         */
        fun clean(reported: String?): String? {
            if (reported.isNullOrEmpty() || reported == WITHHELD) return null
            val quoted = reported.length >= 2 && reported.startsWith('"') && reported.endsWith('"')
            return (if (quoted) reported.substring(1, reported.length - 1) else reported).takeIf { it.isNotEmpty() }
        }
    }
}
