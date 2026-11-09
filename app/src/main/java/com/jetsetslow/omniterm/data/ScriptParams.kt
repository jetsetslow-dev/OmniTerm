package com.jetsetslow.omniterm.data

/**
 * Placeholders in a saved script: `{{vmid}}` asks for a value when the script runs, and
 * `{{service=nginx}}` offers `nginx` as the default. Quick Scripts and Fleet ask for the values
 * once; each host gets them quoted for its own shell.
 *
 * Values are always passed as one shell word, so a placeholder must not sit inside quotes of its
 * own: `systemctl status {{service}}`, not `systemctl status "{{service}}"`. That quoting is what
 * keeps a value such as `x; rm -rf /` an argument instead of a second command.
 *
 * `{{host.name}}` and the other [HOST_VARS] are never asked: each host fills them in with its own
 * details ([HostVars]), quoted the same way.
 *
 * Idea credit: Semaphore UI's survey variables (semaphoreui/semaphore#904); the per-host ones,
 * Termix Fleets' `$HOST` variables (docs.termix.site/plugins/fleets).
 */
object ScriptParams {
    /** One placeholder: its name and the default the form starts with (empty when none). */
    data class Param(val name: String, val default: String)

    /** Which quoting rules a value needs: POSIX sh, or a Windows login shell (cmd or PowerShell). */
    enum class Shell { Posix, Windows }

    /** A value [fill] could not pass to the host's shell safely. */
    class UnsafeValueException(val param: String, message: String) : IllegalArgumentException(message)

    /**
     * What one host fills `{{host.…}}` with: its saved name, address, user, port and group, and
     * [os] as [RemoteCommands.normaliseOs] names it, given to the script as `linux`, `bsd`,
     * `macos` or `windows`.
     */
    data class HostVars(val name: String, val address: String, val user: String, val port: Int, val os: String, val group: String) {
        internal fun value(key: String): String? = when (key) {
            "name" -> name
            "address" -> address
            "user" -> user
            "port" -> port.toString()
            "os" -> when (os) {
                "Windows" -> "windows"
                "Darwin" -> "macos"
                "FreeBSD" -> "bsd"
                else -> "linux"
            }
            "group" -> group
            else -> null
        }

        companion object {
            fun of(srv: ServerEntity, os: String) = HostVars(srv.name, srv.host, srv.username, srv.port, os, srv.groupName.orEmpty())
        }
    }

    /** The `{{host.…}}` names, in the order the help lists them. */
    val HOST_VARS = listOf("name", "address", "user", "port", "os", "group")

    private val PLACEHOLDER = Regex("""\{\{\s*([A-Za-z_][A-Za-z0-9_]{0,31})\s*(?:=([^{}\r\n]*))?\}\}""")

    // A host variable or a placeholder, matched in one pass: a value is never searched again for
    // either, so a value written as {{host.name}} stays the text it is, quoted.
    private val TOKEN = Regex("""\{\{\s*(?:host\.([a-z]+)\s*|([A-Za-z_][A-Za-z0-9_]{0,31})\s*(?:=([^{}\r\n]*))?)\}\}""")

    // Characters that mean the same thing to sh, cmd and PowerShell when left unquoted.
    private val BARE_WORD = Regex("""[A-Za-z0-9._:/@+,=-]+""")

    // Inside "…" cmd still expands %VAR% (and !VAR! with delayed expansion), and PowerShell expands
    // $var and `escapes, so a Windows value holding any of these cannot be quoted for both shells.
    private val WINDOWS_UNQUOTABLE = Regex("""["%!$`\r\n]""")

    private const val MAX_VALUE_LENGTH = 4096

    /** The placeholders in [command], in the order they first appear; a repeated name is asked once. */
    fun parse(command: String): List<Param> =
        PLACEHOLDER.findAll(command)
            .map { Param(it.groupValues[1], it.groupValues[2].trim()) }
            .distinctBy { it.name }
            .toList()

    fun hasParams(command: String): Boolean = PLACEHOLDER.containsMatchIn(command)

    /** Whether [command] uses any of [HOST_VARS]. */
    fun usesHostVars(command: String): Boolean =
        TOKEN.findAll(command).any { it.groupValues[1] in HOST_VARS }

    /** Whether [fill] would change [command] on a host: it has placeholders or host variables. */
    fun needsFill(command: String): Boolean = hasParams(command) || usesHostVars(command)

    /**
     * [command] with each placeholder replaced by its value from [values], and, given [host], each
     * of [HOST_VARS] by that host's, all quoted for [shell]. Without [host], and for a name that is
     * not one of [HOST_VARS], `{{host.…}}` is left as written.
     */
    fun fill(command: String, values: Map<String, String>, shell: Shell, host: HostVars? = null): String =
        TOKEN.replace(command) { match ->
            val hostKey = match.groupValues[1]
            if (hostKey.isNotEmpty()) {
                val value = host?.value(hostKey) ?: return@replace match.value
                quote("host.$hostKey", value, shell)
            } else {
                val name = match.groupValues[2]
                quote(name, values[name] ?: match.groupValues[3].trim(), shell)
            }
        }

    /** Fills [command] for display in a confirmation dialog, the way a Unix host will receive it. */
    fun preview(command: String, values: Map<String, String>): String =
        runCatching { fill(command, values, Shell.Posix) }.getOrDefault(command)

    /** Why [value] cannot be used for [name] on [shell], or null when it can. */
    fun problem(name: String, value: String, shell: Shell): String? =
        runCatching { quote(name, value, shell) }.exceptionOrNull()?.message

    fun shellFor(os: String): Shell = if (RemoteCommands.hasUnixShell(os)) Shell.Posix else Shell.Windows

    private fun quote(name: String, value: String, shell: Shell): String {
        if (value.length > MAX_VALUE_LENGTH) {
            throw UnsafeValueException(name, "The value for $name is longer than $MAX_VALUE_LENGTH characters.")
        }
        if (value.any { it.code < 0x20 && it != '\n' && it != '\t' } || value.contains('\u007f')) {
            throw UnsafeValueException(name, "The value for $name contains control characters.")
        }
        if (BARE_WORD.matches(value)) return value
        return when (shell) {
            Shell.Posix -> "'" + value.replace("'", "'\\''") + "'"
            Shell.Windows -> {
                if (WINDOWS_UNQUOTABLE.containsMatchIn(value)) {
                    throw UnsafeValueException(
                        name,
                        "The value for $name contains \" % ! \$ ` or a line break, which a Windows shell would expand.",
                    )
                }
                "\"$value\""
            }
        }
    }
}
