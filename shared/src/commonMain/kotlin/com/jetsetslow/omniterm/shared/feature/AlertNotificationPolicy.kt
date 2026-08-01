package com.jetsetslow.omniterm.shared.feature

import com.jetsetslow.omniterm.shared.platform.AlertNotification
import com.jetsetslow.omniterm.shared.platform.NotificationRoute
import com.jetsetslow.omniterm.ui.MeasurementSystem
import com.jetsetslow.omniterm.ui.celsiusToDisplay
import com.jetsetslow.omniterm.ui.temperatureUnit
import kotlin.math.abs
import kotlin.math.roundToLong

/** The alert-rule fields a notification needs, without either platform's row type. */
data class AlertRuleSummary(
    val ruleId: Int,
    val serverId: Int,
    val serverName: String,
    val severity: String,
    val metricName: String,
    val thresholdValue: Float,
    val mountPoint: String = "",
)

/**
 * Notification content for a fired alert, ported from Android's `postAlertNotification` so an alert
 * reads identically on both platforms.
 *
 * The host is named by the name its owner typed, never by its address, which is what keeps the body
 * safe on a lock screen — the same reasoning as [HostDisplayPolicy].
 */
object AlertNotificationPolicy {
    /**
     * Stable per-(rule, host) key. Android hashes this string into an `int` notification id; iOS can
     * use the string directly. Re-firing the same rule for the same host replaces its notification
     * instead of stacking a new one.
     */
    fun notificationKey(ruleId: Int, serverId: Int): String = "alert_${ruleId}_$serverId"

    /** `omniterm://notification/alert/{ruleId}/{serverId}`, the link Android's alert intent carries. */
    fun deepLink(ruleId: Int, serverId: Int): String = "omniterm://notification/alert/$ruleId/$serverId"

    fun title(rule: AlertRuleSummary): String = "${rule.severity}: ${rule.serverName}"

    /**
     * `Disk Usage on /var at 91% (threshold 85%)`. The mount point is appended only for disk rules
     * that name one, latency is milliseconds, and temperatures are converted to the display system
     * on both sides of the comparison so the two numbers are never in different units.
     */
    fun body(rule: AlertRuleSummary, value: Float, system: MeasurementSystem): String {
        val mountSuffix = if (rule.metricName == "Disk Usage" && rule.mountPoint.isNotBlank()) {
            " on ${rule.mountPoint}"
        } else {
            ""
        }
        val unit = when (rule.metricName) {
            "Latency" -> "ms"
            "Temperature" -> temperatureUnit(system)
            else -> "%"
        }
        val shownValue = if (rule.metricName == "Temperature") celsiusToDisplay(value, system) else value
        val shownThreshold =
            if (rule.metricName == "Temperature") celsiusToDisplay(rule.thresholdValue, system) else rule.thresholdValue
        return "${rule.metricName}$mountSuffix at ${round0(shownValue)}$unit " +
            "(threshold ${round0(shownThreshold)}$unit)"
    }

    fun build(rule: AlertRuleSummary, value: Float, system: MeasurementSystem): AlertNotification =
        AlertNotification(
            id = notificationKey(rule.ruleId, rule.serverId),
            title = title(rule),
            body = body(rule, value, system),
            route = NotificationRoute(hostId = rule.serverId, alertId = rule.ruleId),
            // Android never suppresses an alert body: the host is identified by its user-given name,
            // so there is nothing sensitive to hide. iOS keeps the same default.
            private = false,
        )

    /**
     * The notification keys to remove when alerts stop breaching or are acknowledged, so a resolved
     * alert cannot sit in the shade claiming a host is still in trouble.
     */
    fun keysToRemove(delivered: Set<String>, stillFiring: Set<String>): Set<String> = delivered - stillFiring

    private fun round0(value: Float): String {
        // Matches Java's "%.0f" for the values an alert can carry: half-up, away from zero.
        val scaled = value.toDouble().roundToLong()
        return if (scaled == 0L && value < 0f) "-0" else abs(scaled).let { if (scaled < 0) "-$it" else "$it" }
    }
}
