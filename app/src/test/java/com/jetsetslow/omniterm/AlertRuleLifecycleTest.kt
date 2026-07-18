package com.jetsetslow.omniterm

import com.jetsetslow.omniterm.data.AlertRuleEntity
import com.jetsetslow.omniterm.ui.alertRuleEvaluationChanged
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class AlertRuleLifecycleTest {
    private val base = AlertRuleEntity(
        id = 9,
        serverId = 4,
        metricName = "CPU Usage",
        thresholdValue = 80f,
        severity = "CRITICAL",
        notes = "runbook A",
    )

    @Test
    fun notesOnlyEditKeepsTheLiveIncident() {
        assertFalse(alertRuleEvaluationChanged(base, base.copy(notes = "runbook B")))
    }

    @Test
    fun everyEvaluationFieldInvalidatesTheLiveIncident() {
        val changes = listOf(
            base.copy(serverId = 5),
            base.copy(metricName = "Memory Usage"),
            base.copy(mountPoint = "/data"),
            base.copy(thresholdValue = 81f),
            base.copy(severity = "WARNING"),
            base.copy(triggerWindow = "10m"),
            base.copy(enabled = false),
        )
        changes.forEach { assertTrue(alertRuleEvaluationChanged(base, it)) }
    }
}
