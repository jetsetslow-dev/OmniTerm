package com.jetsetslow.omniterm.ui

/**
 * Validators for typed numeric input.
 *
 * Every one returns null when the text is usable, or a short reason to show on the field. They exist
 * because the screens used to parse with `text.toIntOrNull() ?: default`: an empty or malformed entry
 * silently became a default, so a saved record held a value the user never typed (a port they never
 * chose, an alert threshold that never fires). Refusing to save is always better than inventing one.
 *
 * Callers should both disable the confirm action while an error is present and surface the message,
 * so the reason is visible rather than the button being mysteriously dead.
 */

/** TCP/UDP port. Rejects 0, which is "any port" to the kernel and never what a user means here. */
fun portError(input: String): String? {
    val trimmed = input.trim()
    if (trimmed.isEmpty()) return "Required"
    val value = trimmed.toIntOrNull() ?: return "Must be a whole number"
    return if (value !in 1..65535) "Must be 1-65535" else null
}

/** A count that must be at least [min] (retries, replicas, and similar). */
fun countError(input: String, min: Int = 1, max: Int = 9_999): String? {
    val trimmed = input.trim()
    if (trimmed.isEmpty()) return "Required"
    val value = trimmed.toIntOrNull() ?: return "Must be a whole number"
    return if (value !in min..max) "Must be $min-$max" else null
}

/** A 0-100 percentage, used for health-score thresholds. */
fun percentError(input: String): String? {
    val trimmed = input.trim()
    if (trimmed.isEmpty()) return "Required"
    val value = trimmed.toFloatOrNull() ?: return "Must be a number"
    if (!value.isFinite()) return "Must be a number"
    return when {
        value < 0f -> "Must be 0 or more"
        value > 100f -> "Must be 100 or less"
        else -> null
    }
}

/** A MAC address in colon or hyphen separated hex, as Wake-on-LAN requires. */
fun macAddressError(input: String): String? {
    val trimmed = input.trim()
    if (trimmed.isEmpty()) return "Required"
    val normalized = trimmed.replace('-', ':')
    val octets = normalized.split(':')
    if (octets.size != 6 || octets.any { it.length != 2 || it.toIntOrNull(radix = 16) == null }) {
        return "Use the form AA:BB:CC:DD:EE:FF"
    }
    return null
}
