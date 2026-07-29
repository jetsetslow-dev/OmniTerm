package com.jetsetslow.omniterm.ui

import com.jetsetslow.omniterm.data.MetricHistoryEntity
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone

internal data class TimedMetricPoint(
    val timestamp: Long,
    val value: Float,
)

internal data class HourlyMetricSeries(
    val cpu: List<TimedMetricPoint>,
    val ram: List<TimedMetricPoint>,
    val temperature: List<TimedMetricPoint>,
)

/**
 * Condenses retained telemetry into one point per clock hour. Temperature buckets are omitted when
 * no sensor value was recorded, allowing the UI to hide that chart without inventing zeroes.
 */
internal fun buildHourlyMetricSeries(history: List<MetricHistoryEntity>): HourlyMetricSeries {
    val buckets = history.groupBy { it.timestamp / HOUR_MS }.toSortedMap()
    return HourlyMetricSeries(
        cpu = buckets.map { (hour, rows) ->
            TimedMetricPoint(hour * HOUR_MS, rows.map { it.cpuUsage }.average().toFloat())
        },
        ram = buckets.map { (hour, rows) ->
            TimedMetricPoint(hour * HOUR_MS, rows.map { it.ramUsage }.average().toFloat())
        },
        temperature = buckets.mapNotNull { (hour, rows) ->
            val readings = rows.mapNotNull { it.cpuTemperatureC }
            readings.takeIf { it.isNotEmpty() }?.let {
                TimedMetricPoint(hour * HOUR_MS, it.average().toFloat())
            }
        },
    )
}

/**
 * Produces compact, real endpoint timestamps for a chart. A date is included when the endpoints
 * cross a local calendar day; short same-day live ranges retain seconds.
 */
internal fun chartEndpointLabels(
    timestamps: List<Long>,
    locale: Locale = Locale.getDefault(),
    timeZone: TimeZone = TimeZone.getDefault(),
): Pair<String, String> {
    if (timestamps.isEmpty()) return "—" to "—"
    val first = timestamps.first()
    val last = timestamps.last()
    val dayFormat = SimpleDateFormat("yyyyMMdd", Locale.ROOT).apply { this.timeZone = timeZone }
    val crossesDay = dayFormat.format(Date(first)) != dayFormat.format(Date(last))
    val pattern = when {
        crossesDay -> "MMM d HH:mm"
        last - first < HOUR_MS -> "HH:mm:ss"
        else -> "HH:mm"
    }
    val formatter = SimpleDateFormat(pattern, locale).apply { this.timeZone = timeZone }
    return formatter.format(Date(first)) to formatter.format(Date(last))
}

private const val HOUR_MS = 3_600_000L
