package com.jetsetslow.omniterm.shared.core

private val PRIVATE_KEY = Regex("-----BEGIN [^-]*PRIVATE KEY-----[\\s\\S]*?-----END [^-]*PRIVATE KEY-----")
private val PASSWORD = Regex("(?i)(password|passphrase|token|authorization)(\\s*[:=]\\s*)([^\\s,;]+)")
private val IPV4 = Regex("(?<![A-Za-z0-9])(?:\\d{1,3}\\.){3}\\d{1,3}(?![A-Za-z0-9])")
private val HOSTNAME = Regex("(?i)(?<![/@])\\b(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\\.)+[a-z]{2,63}\\b")
private val UNIX_PATH = Regex("(?<![A-Za-z0-9])/(?:[^\\s/]+/)*[^\\s,;]*")
private val COMMAND = Regex("(?i)(command|cmd)(\\s*[:=]\\s*)([^\\r\\n]+)")

data class RedactionPolicy(
    val privacyMode: Boolean,
    val maskPaths: Boolean = true,
    val maskCommands: Boolean = true,
)

fun redactDiagnostic(value: String, policy: RedactionPolicy): String {
    var result = value
        .replace(PRIVATE_KEY, "<private-key>")
        .replace(PASSWORD) { "${it.groupValues[1]}${it.groupValues[2]}<redacted>" }
    if (policy.maskCommands) result = result.replace(COMMAND) { "${it.groupValues[1]}${it.groupValues[2]}<command>" }
    if (policy.maskPaths) result = result.replace(UNIX_PATH, "<path>")
    if (policy.privacyMode) {
        result = result.replace(IPV4, "<host>").replace(HOSTNAME, "<host>")
    }
    return result
}

class RedactingDiagnosticLogger(
    private val delegate: DiagnosticLogger,
    private val policy: () -> RedactionPolicy,
) : DiagnosticLogger {
    override fun log(event: DiagnosticEvent) {
        val activePolicy = policy()
        delegate.log(event.copy(fields = event.fields.mapValues { redactDiagnostic(it.value, activePolicy) }))
    }
}
