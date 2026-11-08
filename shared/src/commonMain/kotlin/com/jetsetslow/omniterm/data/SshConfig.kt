package com.jetsetslow.omniterm.data

/** A jump host an ssh_config entry reaches its host through. */
data class SshConfigJump(val host: String, val port: Int, val user: String, val identityFile: String?)

/**
 * One host an ssh_config file names, with the settings OmniTerm can use. [user] is empty when the
 * file does not set one. [notes] says, in plain words, what the file set that OmniTerm did not take.
 */
data class SshConfigHost(
    val alias: String,
    val hostName: String,
    val port: Int,
    val user: String,
    val identityFile: String?,
    val jump: SshConfigJump?,
    val forwardAgent: Boolean,
    val compression: Boolean,
    val keepAliveSeconds: Int?,
    val notes: List<String>,
)

/** What an ssh_config file holds: its hosts, and what was left out of the whole file. */
data class SshConfigFile(val hosts: List<SshConfigHost>, val skipped: List<String>)

/**
 * Reads an OpenSSH client config (`~/.ssh/config`) the way `ssh` does, as far as a phone can.
 *
 * Every `Host` line names patterns; each pattern without wildcards or negation is a host to offer,
 * under the first such name on its line. A host's settings come from every block whose patterns
 * match it, in file order, and the first value of each keyword wins, so `Host *` defaults at the
 * end fill in what a host leaves unset. `Match` blocks and `Include` cannot be followed here and
 * are reported as skipped.
 */
object SshConfigParser {
    private class Block(val patterns: List<String>, val settings: MutableList<Pair<String, String>> = mutableListOf())

    fun parse(text: String): SshConfigFile {
        val blocks = mutableListOf(Block(listOf("*")))  // settings before the first Host apply to all
        val skipped = linkedSetOf<String>()
        var inMatch = false
        for (raw in text.lineSequence()) {
            val (keyword, value) = splitLine(raw) ?: continue
            when (keyword) {
                "host" -> {
                    inMatch = false
                    blocks += Block(words(value))
                }
                "match" -> {
                    inMatch = true
                    skipped += "Match blocks are not read; the hosts they set up are imported without their settings."
                }
                "include" -> skipped += "Include $value is not followed; import that file on its own."
                else -> if (!inMatch) blocks.last().settings += keyword to value
            }
        }

        val aliases = blocks.drop(1).mapNotNull { block -> block.patterns.firstOrNull { isConcrete(it) } }.distinct()
        val hosts = aliases.map { alias -> resolve(alias, blocks, aliases) }
        return SshConfigFile(hosts, skipped.toList())
    }

    private fun resolve(alias: String, blocks: List<Block>, aliases: List<String>): SshConfigHost {
        val options = settingsFor(alias, blocks)
        val notes = mutableListOf<String>()
        val hostName = options["hostname"]?.let { expand(it, alias) } ?: alias
        val port = options["port"]?.toIntOrNull()?.takeIf { it in 1..65535 } ?: 22
        val user = options["user"].orEmpty()

        var jump: SshConfigJump? = null
        val proxyJump = options["proxyjump"]
        val proxyCommand = options["proxycommand"]
        if (proxyJump != null && !proxyJump.equals("none", ignoreCase = true)) {
            val hops = proxyJump.split(',').map { it.trim() }.filter { it.isNotEmpty() }
            jump = hops.firstOrNull()?.let { jumpTo(it, blocks, aliases) }
            if (hops.size > 1) notes += "Goes through ${hops.size} jump hosts; only the first, ${hops.first()}, is used."
        } else if (proxyCommand != null && !proxyCommand.equals("none", ignoreCase = true)) {
            jump = proxyCommandJump(proxyCommand)?.let { jumpTo(it, blocks, aliases) }
            if (jump == null) notes += "Its ProxyCommand is not supported."
        }

        listOf("localforward" to "local", "remoteforward" to "remote", "dynamicforward" to "dynamic").forEach { (key, kind) ->
            if (options.containsKey(key)) notes += "Its $kind port forwards are not imported."
        }
        return SshConfigHost(
            alias = alias,
            hostName = hostName,
            port = port,
            user = user,
            identityFile = options["identityfile"],
            jump = jump,
            forwardAgent = options["forwardagent"].isYes(),
            compression = options["compression"].isYes(),
            keepAliveSeconds = options["serveraliveinterval"]?.toIntOrNull()?.takeIf { it > 0 },
            notes = notes,
        )
    }

    /** `[user@]host[:port]`, where host may itself be an alias in the same file. */
    private fun jumpTo(hop: String, blocks: List<Block>, aliases: List<String>): SshConfigJump {
        val userPart = hop.substringBefore('@', missingDelimiterValue = "")
        val hostPort = hop.substringAfter('@')
        val (name, explicitPort) = if (hostPort.startsWith("[")) {
            hostPort.substringAfter('[').substringBefore(']') to hostPort.substringAfter("]:", "").toIntOrNull()
        } else if (hostPort.count { it == ':' } == 1) {
            hostPort.substringBefore(':') to hostPort.substringAfter(':').toIntOrNull()
        } else {
            hostPort to null
        }
        val options = if (name in aliases) settingsFor(name, blocks) else emptyMap()
        return SshConfigJump(
            host = options["hostname"]?.let { expand(it, name) } ?: name,
            port = explicitPort ?: options["port"]?.toIntOrNull() ?: 22,
            user = userPart.ifEmpty { options["user"].orEmpty() },
            identityFile = options["identityfile"],
        )
    }

    /** The common `ssh -W %h:%p bastion` form, which is a jump host by another name. */
    private fun proxyCommandJump(command: String): String? {
        val parts = words(command)
        if (parts.firstOrNull()?.substringAfterLast('/') != "ssh" || "-W" !in parts) return null
        var port: Int? = null
        var target: String? = null
        var i = 1
        while (i < parts.size) {
            val part = parts[i]
            when {
                part == "-W" || part == "-l" || part == "-i" || part == "-F" || part == "-o" -> i++
                part == "-p" -> { port = parts.getOrNull(i + 1)?.toIntOrNull(); i++ }
                part.startsWith("-") -> Unit
                else -> target = part
            }
            i++
        }
        return target?.let { if (port != null) "$it:$port" else it }
    }

    private fun settingsFor(alias: String, blocks: List<Block>): Map<String, String> {
        val options = LinkedHashMap<String, String>()
        for (block in blocks) {
            if (!matches(alias, block.patterns)) continue
            // The first value given for an option wins, as in ssh_config.
            for ((key, value) in block.settings) options.getOrPut(key) { value }
        }
        return options
    }

    private fun matches(alias: String, patterns: List<String>): Boolean {
        var matched = false
        for (pattern in patterns) {
            if (pattern.startsWith("!")) {
                if (glob(pattern.substring(1), alias)) return false
            } else if (glob(pattern, alias)) {
                matched = true
            }
        }
        return matched
    }

    private fun glob(pattern: String, text: String): Boolean {
        val regex = buildString {
            for (c in pattern) when (c) {
                '*' -> append(".*")
                '?' -> append('.')
                else -> append(Regex.escape(c.toString()))
            }
        }
        return Regex(regex, RegexOption.IGNORE_CASE).matches(text)
    }

    private fun isConcrete(pattern: String) = pattern.none { it == '*' || it == '?' || it == '!' }

    /** `%h` is the alias, `%%` a percent sign. */
    private fun expand(value: String, alias: String) = value.replace("%%", "\u0000").replace("%h", alias).replace("\u0000", "%")

    /** A config line's keyword (lowercase) and value, or null for a blank line or a comment. */
    private fun splitLine(raw: String): Pair<String, String>? {
        val line = raw.trim()
        if (line.isEmpty() || line.startsWith("#")) return null
        val match = Regex("""^(\S+?)(?:\s*=\s*|\s+)(.*)$""").find(line) ?: return null
        val value = match.groupValues[2].trim().let { if (it.length >= 2 && it.startsWith('"') && it.endsWith('"')) it.substring(1, it.length - 1) else it }
        return match.groupValues[1].lowercase() to value
    }

    /** Whitespace-separated words, keeping "quoted words" whole. */
    private fun words(value: String): List<String> =
        Regex(""""([^"]*)"|(\S+)""").findAll(value).map { it.groupValues[1].ifEmpty { it.groupValues[2] } }.toList()

    private fun String?.isYes() = this.equals("yes", ignoreCase = true)
}
