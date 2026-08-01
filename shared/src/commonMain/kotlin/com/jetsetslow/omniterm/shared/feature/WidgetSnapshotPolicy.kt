package com.jetsetslow.omniterm.shared.feature

import com.jetsetslow.omniterm.shared.platform.WidgetSnapshot
import com.jetsetslow.omniterm.ui.MeasurementSystem
import com.jetsetslow.omniterm.ui.formatTemperature

/** Matches the three states the Android widget renders: online, connecting, everything else. */
enum class WidgetHostStatus(val setting: String) {
    Online("online"),
    Connecting("connecting"),
    Offline("offline");

    companion object {
        fun fromServerStatus(value: String?): WidgetHostStatus =
            entries.firstOrNull { it.setting == value } ?: Offline
    }
}

/**
 * One widget row. It deliberately carries the same fields the Android widget draws — the user-given
 * name, a status, a health score, and a formatted metric line — and nothing else. No address, user,
 * port, or secret reference may appear here: the snapshot is written to a shared container (Android
 * widget data / iOS App Group) that other processes can read.
 *
 * Privacy needs no extra masking at this layer: like Android's `HostDisplay`, the widget identifies
 * a host by the name its owner typed, never by its address.
 */
data class WidgetHostLine(
    val hostId: Int,
    val name: String,
    val status: WidgetHostStatus,
    val healthScore: Int,
    val metrics: String,
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

/** Android's `R.string.widget_unnamed_host`. */
const val WIDGET_UNNAMED_HOST: String = "Unnamed host"

private const val WIDGET_METRIC_PLACEHOLDER = "CPU — · RAM — · TEMP — · DISK —"

/** Telemetry as the widget needs it: whole percents, optional temperature. */
data class WidgetMetricSample(
    val cpuPercent: Float,
    val ramPercent: Float,
    val diskPercent: Float,
    val cpuTemperatureC: Float? = null,
)

/** One host as the widget stores it: the row plus the freshest persisted sample, which may be null. */
data class WidgetHostInput(
    val hostId: Int,
    val name: String,
    val status: WidgetHostStatus,
    val healthScore: Int,
    val sample: WidgetMetricSample? = null,
)

/** Android's `R.string.widget_health` / `widget_connecting` / `widget_offline`. */
fun widgetStatusText(status: WidgetHostStatus, healthScore: Int): String = when (status) {
    WidgetHostStatus.Online -> "HP $healthScore"
    WidgetHostStatus.Connecting -> "…"
    WidgetHostStatus.Offline -> "offline"
}

/**
 * Android's `R.string.widget_metrics`, em-dash placeholders included: a row with no stored sample
 * shows dashes rather than zeros, which would read as a healthy idle host.
 */
fun widgetMetricsText(sample: WidgetMetricSample?, system: MeasurementSystem): String {
    if (sample == null) return WIDGET_METRIC_PLACEHOLDER
    val temperature = sample.cpuTemperatureC?.let { formatTemperature(it, system) } ?: "—"
    return "CPU ${sample.cpuPercent.toInt()}% · RAM ${sample.ramPercent.toInt()}% · " +
        "TEMP $temperature · DISK ${sample.diskPercent.toInt()}%"
}

fun widgetHostName(name: String): String = name.takeIf { it.isNotBlank() } ?: WIDGET_UNNAMED_HOST

/**
 * Builds the widget snapshot (IOS-065) with the same row content Android renders, so both platforms
 * describe a fleet identically.
 */
fun buildWidgetSnapshot(
    hosts: List<WidgetHostInput>,
    nowEpochMillis: Long,
    system: MeasurementSystem = MeasurementSystem.Metric,
): WidgetFleetSnapshot = WidgetFleetSnapshot(
    generatedAtEpochMillis = nowEpochMillis,
    lines = hosts.map {
        WidgetHostLine(
            hostId = it.hostId,
            name = widgetHostName(it.name),
            status = it.status,
            healthScore = it.healthScore,
            metrics = widgetMetricsText(it.sample, system),
        )
    },
    // "Connecting" is not online: counting it would overstate a fleet that is still dialling.
    online = hosts.count { it.status == WidgetHostStatus.Online },
    total = hosts.size,
    stale = false,
)

/** Marks an existing snapshot stale for display; the data is kept so the widget is not blank. */
fun ageWidgetSnapshot(
    snapshot: WidgetFleetSnapshot,
    nowEpochMillis: Long,
    staleAfterMillis: Long = WIDGET_STALE_AFTER_MILLIS,
): WidgetFleetSnapshot = snapshot.copy(stale = nowEpochMillis - snapshot.generatedAtEpochMillis >= staleAfterMillis)

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
