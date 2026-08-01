package com.jetsetslow.omniterm.shared.feature

import com.jetsetslow.omniterm.shared.platform.WidgetSnapshot

/**
 * One row of the fleet widget. It carries only what is drawn: no endpoint, user, port, secret
 * reference, or command output may appear here, because the snapshot is written to a shared
 * container (Android widget data / iOS App Group) that other processes can read.
 */
data class WidgetHostLine(
    val hostId: Int,
    val label: String,
    val online: Boolean,
    val detail: String,
)

data class WidgetFleetSnapshot(
    val generatedAtEpochMillis: Long,
    val lines: List<WidgetHostLine>,
    val online: Int,
    val total: Int,
    val stale: Boolean = false,
) {
    fun toPublishable(): WidgetSnapshot = WidgetSnapshot(generatedAtEpochMillis, online, total, stale)
}

/** Beyond this the widget must say it is showing old data rather than imply a live reading. */
const val WIDGET_STALE_AFTER_MILLIS: Long = 30 * 60 * 1000L

private fun maskedLabel(name: String): String {
    val visible = name.trim().take(1)
    return if (visible.isEmpty()) "Host" else "$visible•••"
}

/**
 * Builds the widget snapshot (IOS-065). Masking is applied here, once, so neither platform's widget
 * code has to remember it.
 */
fun buildWidgetSnapshot(
    readings: List<FleetReading>,
    nowEpochMillis: Long,
    privacyMode: Boolean,
): WidgetFleetSnapshot {
    val lines = readings.map { reading ->
        WidgetHostLine(
            hostId = reading.host.id,
            label = if (privacyMode) maskedLabel(reading.host.name) else reading.host.name,
            online = reading.reachable,
            // Metric detail is a coarse summary; privacy mode drops it entirely because CPU/memory
            // figures on a lock screen still describe a machine the viewer may not own.
            detail = when {
                privacyMode -> if (reading.reachable) "Online" else "Offline"
                !reading.reachable -> "Offline"
                reading.metrics == null -> "No data"
                else -> "Online"
            },
        )
    }
    return WidgetFleetSnapshot(
        generatedAtEpochMillis = nowEpochMillis,
        lines = lines,
        online = readings.count { it.reachable },
        total = readings.size,
        stale = false,
    )
}

/** Marks an existing snapshot stale for display; the data itself is kept so the widget is not blank. */
fun ageWidgetSnapshot(
    snapshot: WidgetFleetSnapshot,
    nowEpochMillis: Long,
    staleAfterMillis: Long = WIDGET_STALE_AFTER_MILLIS,
): WidgetFleetSnapshot {
    val age = nowEpochMillis - snapshot.generatedAtEpochMillis
    return snapshot.copy(stale = age >= staleAfterMillis)
}

/**
 * True when the widget timeline should be reloaded. The generation timestamp alone is deliberately
 * ignored: reloading on every refresh would spend the platform's limited widget budget redrawing an
 * identical view.
 */
fun shouldReloadWidgetTimeline(previous: WidgetFleetSnapshot?, next: WidgetFleetSnapshot): Boolean {
    if (previous == null) return true
    return previous.lines != next.lines ||
        previous.online != next.online ||
        previous.total != next.total ||
        previous.stale != next.stale
}
