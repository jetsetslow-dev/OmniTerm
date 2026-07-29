package com.jetsetslow.omniterm

import com.jetsetslow.omniterm.data.AlertRuleEntity
import com.jetsetslow.omniterm.data.QuickScriptEntity
import com.jetsetslow.omniterm.ui.DEFAULT_ALERT_RULE_PRESETS
import com.jetsetslow.omniterm.ui.isPristinePresetRule
import com.jetsetslow.omniterm.ui.isPristinePresetScript
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class PresetBackupFilterTest {
    private val scriptPreset = QuickScriptEntity(
        emoji = "CPU",
        name = "CPU/RAM",
        command = "top -b -n1",
        color = "cyan",
        category = "Fleet",
        availableForQuick = false,
        availableForFleet = true,
        presetKey = "fleet.cpu",
    )

    private val alertPreset = AlertRuleEntity(
        serverId = 0,
        metricName = "CPU Usage",
        thresholdValue = 90f,
        severity = "CRITICAL",
        presetKey = "alert.cpu",
    )

    @Test
    fun onlyExactScriptPresetIsPristine() {
        assertTrue(isPristinePresetScript(scriptPreset.copy(id = 42), listOf(scriptPreset)))
        assertFalse(isPristinePresetScript(scriptPreset.copy(name = "My CPU check"), listOf(scriptPreset)))
        assertFalse(isPristinePresetScript(scriptPreset.copy(availableForQuick = true), listOf(scriptPreset)))
        assertFalse(isPristinePresetScript(scriptPreset.copy(notes = "Run during incidents"), listOf(scriptPreset)))
    }

    @Test
    fun alertWindowAndEnabledEditsSurviveBackupFiltering() {
        assertTrue(isPristinePresetRule(alertPreset.copy(id = 42), listOf(alertPreset)))
        assertFalse(isPristinePresetRule(alertPreset.copy(triggerWindow = "15m"), listOf(alertPreset)))
        assertFalse(isPristinePresetRule(alertPreset.copy(enabled = false), listOf(alertPreset)))
        assertFalse(isPristinePresetRule(alertPreset.copy(notes = "After-hours only"), listOf(alertPreset)))
    }

    @Test
    fun defaultAlertRulesIncludeTemperatureForSensorCapableHosts() {
        val temperature = DEFAULT_ALERT_RULE_PRESETS.single { it.metricName == "Temperature" }

        assertTrue(temperature.serverId == 0)
        assertTrue(temperature.thresholdValue == 80f)
        assertTrue(temperature.presetKey == "alert.temperature")
    }
}
