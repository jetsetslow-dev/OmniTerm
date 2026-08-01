package com.jetsetslow.omniterm.ui

const val DEFAULT_APP_LOCK_BACKGROUND_TIMEOUT_MS = 30_000L
const val MAX_APP_LOCK_BACKGROUND_TIMEOUT_MS = 24 * 60 * 60 * 1000L

private val APP_LOCK_TIMEOUT_PRESET_VALUES_MS = setOf(0L, 30_000L, 60_000L, 300_000L)

fun normalizeAppLockBackgroundTimeout(value: Long?): Long =
    value?.coerceIn(0L, MAX_APP_LOCK_BACKGROUND_TIMEOUT_MS)
        ?: DEFAULT_APP_LOCK_BACKGROUND_TIMEOUT_MS

data class AppLockTimeoutDraft(
    val timeoutMs: Long,
    val customValue: String,
    val customUnit: String,
    val customSelected: Boolean,
) {
    val customTimeoutMs: Long?
        get() = parseAppLockCustomDuration(customValue, customUnit)

    val isValid: Boolean
        get() = !customSelected || customTimeoutMs != null

    fun selectPreset(timeoutMs: Long): AppLockTimeoutDraft =
        copy(timeoutMs = timeoutMs, customSelected = false)

    fun selectCustom(): AppLockTimeoutDraft =
        if (customSelected) {
            this
        } else {
            copy(
                timeoutMs = 10 * 60_000L,
                customValue = "10",
                customUnit = "Minutes",
                customSelected = true,
            )
        }

    fun editCustomValue(input: String): AppLockTimeoutDraft {
        val filtered = input.filter(Char::isDigit).take(5)
        return copy(
            customValue = filtered,
            timeoutMs = parseAppLockCustomDuration(filtered, customUnit) ?: timeoutMs,
        )
    }

    fun selectCustomUnit(unit: String): AppLockTimeoutDraft =
        copy(
            customUnit = unit,
            timeoutMs = parseAppLockCustomDuration(customValue, unit) ?: timeoutMs,
        )

    companion object {
        fun fromTimeout(timeoutMs: Long): AppLockTimeoutDraft {
            val (value, unit) = appLockCustomDurationParts(timeoutMs)
            return AppLockTimeoutDraft(
                timeoutMs = timeoutMs,
                customValue = value,
                customUnit = unit,
                customSelected = timeoutMs !in APP_LOCK_TIMEOUT_PRESET_VALUES_MS,
            )
        }
    }
}

private fun appLockCustomDurationParts(timeoutMs: Long): Pair<String, String> = when {
    timeoutMs > 0L && timeoutMs % 3_600_000L == 0L ->
        (timeoutMs / 3_600_000L).toString() to "Hours"
    timeoutMs > 0L && timeoutMs % 60_000L == 0L ->
        (timeoutMs / 60_000L).toString() to "Minutes"
    timeoutMs > 0L ->
        (timeoutMs / 1_000L).coerceAtLeast(1L).toString() to "Seconds"
    else -> "10" to "Minutes"
}

private fun parseAppLockCustomDuration(value: String, unit: String): Long? {
    val amount = value.toLongOrNull()?.takeIf { it > 0L } ?: return null
    val multiplier = when (unit) {
        "Seconds" -> 1_000L
        "Minutes" -> 60_000L
        "Hours" -> 3_600_000L
        else -> return null
    }
    return (amount * multiplier).takeIf { it in 1L..MAX_APP_LOCK_BACKGROUND_TIMEOUT_MS }
}

fun shouldRecordAppBackground(isChangingConfigurations: Boolean): Boolean =
    !isChangingConfigurations

/**
 * In-process foreground/background tracker for the app lock.
 *
 * The timestamp is deliberately not persisted: process recreation is handled by the stricter
 * cold-start lock. Callers supply monotonic time so wall-clock changes cannot shorten or extend the
 * configured interval.
 */
class AppLockTimeoutTracker {
    private var backgroundedAtMs: Long? = null

    fun noteBackgrounded(nowMs: Long) {
        // Keep the earliest unmatched stop if Android delivers duplicate lifecycle callbacks.
        if (backgroundedAtMs == null) backgroundedAtMs = nowMs
    }

    fun clear() {
        backgroundedAtMs = null
    }

    fun consumeShouldRelock(
        nowMs: Long,
        timeoutMs: Long,
        lockEnabled: Boolean,
        hasPin: Boolean,
    ): Boolean {
        val since = backgroundedAtMs ?: return false
        backgroundedAtMs = null
        if (!lockEnabled || !hasPin || nowMs < since) return false
        return nowMs - since >= normalizeAppLockBackgroundTimeout(timeoutMs)
    }
}
