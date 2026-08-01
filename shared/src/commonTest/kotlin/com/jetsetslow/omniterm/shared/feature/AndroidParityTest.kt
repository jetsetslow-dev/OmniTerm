package com.jetsetslow.omniterm.shared.feature

import com.jetsetslow.omniterm.ui.MeasurementSystem
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * Parity checks against the Android implementations these shared policies were ported from. Where
 * Android has a unit test, the same fixture is used so a divergence shows up as a failure here
 * rather than as two apps that quietly disagree.
 */
class HostDisplayPolicyTest {
    private val host = HostIdentity(name = "prod-db", address = "10.0.0.4", username = "root")

    @Test
    fun hidingSensitiveInfoSubstitutesTheNameForTheAddress() {
        assertEquals("10.0.0.4", HostDisplayPolicy.host(host, hideSensitiveInfo = false))
        assertEquals("prod-db", HostDisplayPolicy.host(host, hideSensitiveInfo = true))
        assertEquals("root@10.0.0.4", HostDisplayPolicy.userAtHost(host, hideSensitiveInfo = false))
        assertEquals("root@prod-db", HostDisplayPolicy.userAtHost(host, hideSensitiveInfo = true))
    }

    @Test
    fun blankNamesFallBackToTheAddressOnlyWhenThatIsAllowed() {
        val unnamed = HostIdentity(name = "", address = "10.0.0.9")
        assertEquals("10.0.0.9", HostDisplayPolicy.name(unnamed, hideSensitiveInfo = false))
        assertEquals("host", HostDisplayPolicy.name(unnamed, hideSensitiveInfo = true))
        assertEquals("host", HostDisplayPolicy.host(unnamed, hideSensitiveInfo = true))
        assertEquals("share", HostDisplayPolicy.shareAddress("", "//nas/media", hideSensitiveInfo = true))
    }

    @Test
    fun valuesWithNoNameToSubstituteAreMasked() {
        assertEquals("aa:bb:cc:dd:ee:ff", HostDisplayPolicy.sensitive("aa:bb:cc:dd:ee:ff", hideSensitiveInfo = false))
        assertEquals("•••", HostDisplayPolicy.sensitive("aa:bb:cc:dd:ee:ff", hideSensitiveInfo = true))
    }
}

class AlertNotificationPolicyTest {
    private val rule = AlertRuleSummary(
        ruleId = 7,
        serverId = 3,
        serverName = "prod-db",
        severity = "Critical",
        metricName = "CPU Usage",
        thresholdValue = 85f,
    )

    @Test
    fun titleAndBodyMatchTheAndroidStrings() {
        val notification = AlertNotificationPolicy.build(rule, value = 91.4f, system = MeasurementSystem.Metric)
        assertEquals("Critical: prod-db", notification.title)
        assertEquals("CPU Usage at 91% (threshold 85%)", notification.body)
        assertEquals("alert_7_3", notification.id)
        assertEquals(3, notification.route.hostId)
        assertEquals(7, notification.route.alertId)
    }

    @Test
    fun diskRulesNameTheirMountPointAndLatencyUsesMilliseconds() {
        val disk = rule.copy(metricName = "Disk Usage", mountPoint = "/var", thresholdValue = 85f)
        assertEquals(
            "Disk Usage on /var at 91% (threshold 85%)",
            AlertNotificationPolicy.body(disk, 91f, MeasurementSystem.Metric),
        )
        // A disk rule without a mount point must not print a dangling " on ".
        assertEquals(
            "Disk Usage at 91% (threshold 85%)",
            AlertNotificationPolicy.body(disk.copy(mountPoint = ""), 91f, MeasurementSystem.Metric),
        )
        val latency = rule.copy(metricName = "Latency", thresholdValue = 200f)
        assertEquals(
            "Latency at 342ms (threshold 200ms)",
            AlertNotificationPolicy.body(latency, 342f, MeasurementSystem.Metric),
        )
    }

    @Test
    fun temperatureConvertsBothSidesSoTheUnitsNeverDisagree() {
        val temperature = rule.copy(metricName = "Temperature", thresholdValue = 70f)
        assertEquals(
            "Temperature at 81°C (threshold 70°C)",
            AlertNotificationPolicy.body(temperature, 81f, MeasurementSystem.Metric),
        )
        assertEquals(
            "Temperature at 178°F (threshold 158°F)",
            AlertNotificationPolicy.body(temperature, 81f, MeasurementSystem.Imperial),
        )
    }

    @Test
    fun refiringTheSameRuleReplacesItsNotification() {
        assertEquals(
            AlertNotificationPolicy.notificationKey(7, 3),
            AlertNotificationPolicy.build(rule, 90f, MeasurementSystem.Metric).id,
        )
        assertEquals("omniterm://notification/alert/7/3", AlertNotificationPolicy.deepLink(7, 3))
    }

    @Test
    fun resolvedAlertsAreRemovedFromTheShade() {
        val delivered = setOf("alert_7_3", "alert_8_3", "alert_9_1")
        val stillFiring = setOf("alert_7_3")
        assertEquals(setOf("alert_8_3", "alert_9_1"), AlertNotificationPolicy.keysToRemove(delivered, stillFiring))
    }
}

class LaunchRoutingTest {
    @Test
    fun theTwoPublishedLinkShapesParse() {
        assertEquals(LaunchRequest.OpenAlert(7, 3), parseLaunchLink("omniterm://notification/alert/7/3"))
        assertEquals(LaunchRequest.ConnectServer(42), parseLaunchLink("omniterm://widget/11/server/42"))
    }

    @Test
    fun anythingElseIsRejectedRatherThanGuessed() {
        listOf(
            "https://notification/alert/7/3",
            "omniterm://notification/alert/7",
            "omniterm://notification/alert/7/3/4",
            "omniterm://notification/alert/abc/3",
            "omniterm://notification/alert/0/3",
            "omniterm://notification/alert/-1/3",
            "omniterm://widget/11/host/42",
            "omniterm://",
            "",
        ).forEach { assertNull(parseLaunchLink(it), "expected rejection for '$it'") }
    }

    @Test
    fun requestsNamingUnknownResourcesAreDropped() {
        val servers = setOf(3, 42)
        val alerts = setOf(7)
        assertEquals(
            LaunchRequest.OpenAlert(7, 3),
            validateLaunchRequest(LaunchRequest.OpenAlert(7, 3), servers, alerts),
        )
        assertNull(validateLaunchRequest(LaunchRequest.OpenAlert(7, 99), servers, alerts))
        assertNull(validateLaunchRequest(LaunchRequest.OpenAlert(99, 3), servers, alerts))
        assertNull(validateLaunchRequest(LaunchRequest.ConnectServer(99), servers))
        assertNull(validateLaunchRequest(LaunchRequest.OpenSplit(3, 99), servers))
        assertNull(validateLaunchRequest(LaunchRequest.OpenShare(1), servers))
        assertNull(validateLaunchRequest(LaunchRequest.ResumeSession("gone"), servers))
        assertEquals(LaunchRequest.OpenSftp, validateLaunchRequest(LaunchRequest.OpenSftp, servers))
    }

    @Test
    fun aRepeatedRequestIsNotQueuedTwice() {
        val queue = LaunchRequestQueue()
        queue.enqueue(LaunchRequest.ConnectServer(3))
        queue.enqueue(LaunchRequest.ConnectServer(3))
        assertEquals(1, queue.size, "a re-delivered intent must not reconnect twice")
        queue.enqueue(LaunchRequest.OpenSftp)
        queue.enqueue(LaunchRequest.ConnectServer(3))
        assertEquals(3, queue.size, "only an immediate repeat is collapsed")
    }

    @Test
    fun nothingDrainsWhileLockedOrStillLoading() {
        val queue = LaunchRequestQueue()
        queue.enqueue(LaunchRequest.ConnectServer(3))

        assertTrue(queue.drain(settingsLoaded = false, locked = false).isEmpty())
        assertTrue(queue.drain(settingsLoaded = true, locked = true).isEmpty(), "a tap must not walk past the lock")
        assertEquals(1, queue.size, "held requests survive until the app is ready")

        assertEquals(listOf(LaunchRequest.ConnectServer(3)), queue.drain(settingsLoaded = true, locked = false))
        assertEquals(0, queue.size)
    }

    @Test
    fun clearingDropsPendingPrivilegedActions() {
        val queue = LaunchRequestQueue()
        queue.enqueue(LaunchRequest.ConnectServer(3))
        queue.clear()
        assertTrue(queue.drain(settingsLoaded = true, locked = false).isEmpty())
    }
}

class SessionNotificationPayloadTest {
    @Test
    fun decodePreservesServerNamesWithPipeCharacters() {
        val decoded = decodeSessionNotificationPayload("session-1\nprod|db|primary")
        assertEquals("session-1", decoded?.id)
        assertEquals("prod|db|primary", decoded?.name)
    }

    @Test
    fun decodeRejectsLegacyOrBlankPayloads() {
        assertNull(decodeSessionNotificationPayload("session-1|prod"))
        assertNull(decodeSessionNotificationPayload("\nprod"))
        assertNull(decodeSessionNotificationPayload(""))
    }

    @Test
    fun encodeRoundTrips() {
        val sessions = listOf(
            SessionNotificationPayload("s-1", "prod|db"),
            SessionNotificationPayload("s-2", ""),
        )
        val encoded = encodeSessionNotificationPayloads(sessions)
        assertEquals(sessions, encoded.map { decodeSessionNotificationPayload(it) })
    }
}

class WidgetSnapshotParityTest {
    private val sample = WidgetMetricSample(cpuPercent = 12.7f, ramPercent = 48.2f, diskPercent = 71.9f, cpuTemperatureC = 54.4f)

    @Test
    fun rowsCarryTheSameTextAndroidRenders() {
        val snapshot = buildWidgetSnapshot(
            listOf(
                WidgetHostInput(1, "web-01", WidgetHostStatus.Online, healthScore = 92, sample = sample),
                WidgetHostInput(2, "", WidgetHostStatus.Offline, healthScore = 0),
                WidgetHostInput(3, "app-01", WidgetHostStatus.Connecting, healthScore = 0),
            ),
            nowEpochMillis = 5_000,
        )

        assertEquals(listOf("web-01", WIDGET_UNNAMED_HOST, "app-01"), snapshot.lines.map { it.name })
        // Truncation, not rounding, exactly like Android's Int conversion.
        assertEquals("CPU 12% · RAM 48% · TEMP 54°C · DISK 71%", snapshot.lines[0].metrics)
        assertEquals("CPU — · RAM — · TEMP — · DISK —", snapshot.lines[1].metrics)
        assertEquals("HP 92", widgetStatusText(snapshot.lines[0].status, snapshot.lines[0].healthScore))
        assertEquals("offline", widgetStatusText(snapshot.lines[1].status, 0))
        assertEquals("…", widgetStatusText(snapshot.lines[2].status, 0))
        // Connecting is not online: counting it would overstate a fleet that is still dialling.
        assertEquals(1, snapshot.online)
        assertEquals(3, snapshot.total)
    }

    @Test
    fun temperatureFollowsTheMeasurementSystem() {
        assertEquals(
            "CPU 12% · RAM 48% · TEMP 130°F · DISK 71%",
            widgetMetricsText(sample, MeasurementSystem.Imperial),
        )
        assertEquals(
            "CPU 12% · RAM 48% · TEMP — · DISK 71%",
            widgetMetricsText(sample.copy(cpuTemperatureC = null), MeasurementSystem.Metric),
        )
    }

    @Test
    fun unknownServerStatusReadsAsOffline() {
        assertEquals(WidgetHostStatus.Online, WidgetHostStatus.fromServerStatus("online"))
        assertEquals(WidgetHostStatus.Connecting, WidgetHostStatus.fromServerStatus("connecting"))
        assertEquals(WidgetHostStatus.Offline, WidgetHostStatus.fromServerStatus("unknown"))
        assertEquals(WidgetHostStatus.Offline, WidgetHostStatus.fromServerStatus(null))
    }

    @Test
    fun stalenessAndTimelineReloadFollowDisplayedData() {
        val first = buildWidgetSnapshot(
            listOf(WidgetHostInput(1, "a", WidgetHostStatus.Online, 90, sample)),
            nowEpochMillis = 0,
        )
        val laterSameData = first.copy(generatedAtEpochMillis = 60_000)
        val changed = buildWidgetSnapshot(
            listOf(WidgetHostInput(1, "a", WidgetHostStatus.Offline, 0)),
            nowEpochMillis = 60_000,
        )

        assertFalse(ageWidgetSnapshot(first, WIDGET_STALE_AFTER_MILLIS - 1).stale)
        assertTrue(ageWidgetSnapshot(first, WIDGET_STALE_AFTER_MILLIS).stale)
        assertEquals(1, ageWidgetSnapshot(first, WIDGET_STALE_AFTER_MILLIS).lines.size, "stale data is still shown")

        assertTrue(shouldReloadWidgetTimeline(null, first))
        assertFalse(shouldReloadWidgetTimeline(first, laterSameData), "a new timestamp alone is not a change")
        assertTrue(shouldReloadWidgetTimeline(first, changed))
        assertTrue(shouldReloadWidgetTimeline(first, ageWidgetSnapshot(first, WIDGET_STALE_AFTER_MILLIS)))
    }
}
