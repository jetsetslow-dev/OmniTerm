package com.jetsetslow.omniterm.ui

internal const val DEFAULT_APP_LOCK_BACKGROUND_TIMEOUT_MS = 30_000L
internal const val MAX_APP_LOCK_BACKGROUND_TIMEOUT_MS = 24 * 60 * 60 * 1000L

internal fun normalizeAppLockBackgroundTimeout(value: Long?): Long =
    value?.coerceIn(0L, MAX_APP_LOCK_BACKGROUND_TIMEOUT_MS)
        ?: DEFAULT_APP_LOCK_BACKGROUND_TIMEOUT_MS

internal fun shouldRecordAppBackground(isChangingConfigurations: Boolean): Boolean =
    !isChangingConfigurations

/**
 * In-process foreground/background tracker for the app lock.
 *
 * The timestamp is deliberately not persisted: process recreation is handled by the stricter
 * cold-start lock. Callers supply monotonic time so wall-clock changes cannot shorten or extend the
 * configured interval.
 */
internal class AppLockTimeoutTracker {
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
