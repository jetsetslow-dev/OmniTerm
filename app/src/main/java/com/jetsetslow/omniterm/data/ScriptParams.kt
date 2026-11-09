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
 * Idea credit: Semaphore UI's survey variables (semaphoreui/semaphore#904).
 */
object ScriptParams {
    /** One placeholder: its name and the default the form starts with (empty when none). */
    data class Param(val name: String, val default: String)

    /** Which quoting rules a value needs: POSIX sh, or a Windows login shell (cmd or PowerShell). */
    enum class Shell { Posix, Windows }

    /** A value [fill] could not pass to the host's shell safely. */
    class UnsafeValueException(val param: String, message: String) : IllegalArgumentException(message)

    private val PLACEHOLDER = Regex("""\{\{\s*([A-Za-z_][A-Za-z0-9_]{0,31})\s*(?:=([^{}\r\n]*))?\}\}""")

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

    /** [command] with each placeholder replaced by its value from [values], quoted for [shell]. */
    fun fill(command: String, values: Map<String, String>, shell: Shell): String =
        PLACEHOLDER.replace(command) { match ->
            val name = match.groupValues[1]
            val value = values[name] ?: match.groupValues[2].trim()
            quote(name, value, shell)
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
