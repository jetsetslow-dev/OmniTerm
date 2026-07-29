package com.jetsetslow.omniterm

import com.jetsetslow.omniterm.data.MetricHistoryEntity
import com.jetsetslow.omniterm.ui.buildHourlyMetricSeries
import com.jetsetslow.omniterm.ui.chartEndpointLabels
import java.util.Locale
import java.util.TimeZone
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class MonitorHistoryTest {
    @Test
    fun hourlySeriesAveragesCpuRamAndOnlyObservedTemperatures() {
        val history = listOf(
            metric(timestamp = 1_000, cpu = 20f, ram = 40f, temperature = 70f),
            metric(timestamp = 2_000, cpu = 40f, ram = 60f, temperature = null),
            metric(timestamp = 3_600_500, cpu = 80f, ram = 90f, temperature = null),
        )

        val series = buildHourlyMetricSeries(history)

        assertEquals(listOf(30f, 80f), series.cpu.map { it.value })
        assertEquals(listOf(50f, 90f), series.ram.map { it.value })
        assertEquals(listOf(70f), series.temperature.map { it.value })
        assertEquals(listOf(0L, 3_600_000L), series.cpu.map { it.timestamp })
    }

    @Test
    fun temperatureSeriesIsEmptyWhenHostHasNoSensor() {
        val series = buildHourlyMetricSeries(
            listOf(
                metric(timestamp = 1_000, cpu = 20f, ram = 40f, temperature = null),
                metric(timestamp = 3_600_500, cpu = 30f, ram = 50f, temperature = null),
            )
        )

        assertTrue(series.temperature.isEmpty())
    }

    @Test
    fun endpointLabelsShowRealTimesAndAddDatesAcrossDays() {
        val utc = TimeZone.getTimeZone("UTC")
        assertEquals(
            "00:00:01" to "00:00:31",
            chartEndpointLabels(listOf(1_000, 31_000), Locale.US, utc),
        )
        assertEquals(
            "Jan 1 23:59" to "Jan 2 00:01",
            chartEndpointLabels(
                listOf(86_340_000, 86_460_000),
                Locale.US,
                utc,
            ),
        )
    }

    private fun metric(
        timestamp: Long,
        cpu: Float,
        ram: Float,
        temperature: Float?,
    ) = MetricHistoryEntity(
        serverId = 1,
        timestamp = timestamp,
        cpuUsage = cpu,
        ramUsage = ram,
        diskUsage = 10f,
        latency = 5,
        networkIn = 0f,
        networkOut = 0f,
        cpuTemperatureC = temperature,
    )
}
