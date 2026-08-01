package com.jetsetslow.omniterm.shared.feature

import com.jetsetslow.omniterm.data.HostMetrics
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

private fun reading(id: Int, name: String, reachable: Boolean, metrics: HostMetrics? = null) =
    FleetReading(FleetHost(id, name), metrics, reachable)

private val metrics = HostMetrics(
    cpuPercent = 12f,
    memUsedBytes = 1,
    memTotalBytes = 2,
    diskUsedBytes = 1,
    diskTotalBytes = 2,
    load1 = 0.1f,
    load5 = 0.1f,
    load15 = 0.1f,
    uptimeSeconds = 60,
    procCount = 10,
)

class WidgetSnapshotPolicyTest {
    @Test
    fun snapshotCountsOnlineHostsAndCarriesNoEndpointDetail() {
        val snapshot = buildWidgetSnapshot(
            listOf(reading(1, "web-01", true, metrics), reading(2, "db-01", false), reading(3, "app-01", true)),
            nowEpochMillis = 5_000,
            privacyMode = false,
        )

        assertEquals(2, snapshot.online)
        assertEquals(3, snapshot.total)
        assertEquals(listOf("web-01", "db-01", "app-01"), snapshot.lines.map { it.label })
        // Reachable but unmeasured is "No data": claiming "Online" would overstate what was probed.
        assertEquals(listOf("Online", "Offline", "No data"), snapshot.lines.map { it.detail })
        assertEquals(5_000, snapshot.toPublishable().generatedAtEpochMillis)
    }

    @Test
    fun privacyModeMasksLabelsAndDropsMetricDetail() {
        val snapshot = buildWidgetSnapshot(
            listOf(reading(1, "prod-payments", true, metrics)),
            nowEpochMillis = 0,
            privacyMode = true,
        )

        val line = snapshot.lines.single()
        assertEquals("p•••", line.label)
        assertFalse(line.label.contains("payments"))
        assertEquals("Online", line.detail)
    }

    @Test
    fun snapshotBecomesStaleOnlyAfterTheWindow() {
        val snapshot = buildWidgetSnapshot(listOf(reading(1, "a", true)), nowEpochMillis = 0, privacyMode = false)

        assertFalse(ageWidgetSnapshot(snapshot, WIDGET_STALE_AFTER_MILLIS - 1).stale)
        assertTrue(ageWidgetSnapshot(snapshot, WIDGET_STALE_AFTER_MILLIS).stale)
        // Stale data is still shown; a blank widget would be a worse answer than an old one.
        assertEquals(1, ageWidgetSnapshot(snapshot, WIDGET_STALE_AFTER_MILLIS).lines.size)
    }

    @Test
    fun timelineReloadsOnlyWhenDisplayedDataChanges() {
        val first = buildWidgetSnapshot(listOf(reading(1, "a", true)), nowEpochMillis = 0, privacyMode = false)
        val laterSameData = buildWidgetSnapshot(listOf(reading(1, "a", true)), nowEpochMillis = 60_000, privacyMode = false)
        val changed = buildWidgetSnapshot(listOf(reading(1, "a", false)), nowEpochMillis = 60_000, privacyMode = false)

        assertTrue(shouldReloadWidgetTimeline(null, first))
        assertFalse(shouldReloadWidgetTimeline(first, laterSameData), "a new timestamp alone is not a change")
        assertTrue(shouldReloadWidgetTimeline(first, changed))
        assertTrue(shouldReloadWidgetTimeline(first, ageWidgetSnapshot(first, WIDGET_STALE_AFTER_MILLIS)))
    }
}
