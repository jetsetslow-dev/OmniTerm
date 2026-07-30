package com.jetsetslow.omniterm

import com.jetsetslow.omniterm.ui.MeasurementSystem
import com.jetsetslow.omniterm.ui.alertThresholdError
import com.jetsetslow.omniterm.ui.countError
import com.jetsetslow.omniterm.ui.macAddressError
import com.jetsetslow.omniterm.ui.percentError
import com.jetsetslow.omniterm.ui.portError
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * These all used to parse with `toIntOrNull() ?: default`, so an empty or malformed entry saved a
 * value the user never typed. Each test pins the "refuse, don't invent" behaviour.
 */
class InputValidationTest {

    @Test
    fun `blank input is rejected rather than defaulted`() {
        assertNotNull(portError(""))
        assertNotNull(portError("   "))
        assertNotNull(countError(""))
        assertNotNull(percentError(""))
        assertNotNull(macAddressError(""))
    }

    @Test
    fun `port accepts the valid range and rejects outside it`() {
        assertNull(portError("22"))
        assertNull(portError("1"))
        assertNull(portError("65535"))
        assertNull(portError(" 8080 "))
        // 0 means "any port" to the kernel, never a user's intent here.
        assertNotNull(portError("0"))
        assertNotNull(portError("65536"))
        assertNotNull(portError("-1"))
        assertNotNull(portError("22.5"))
        assertNotNull(portError("abc"))
    }

    @Test
    fun `count respects its bounds`() {
        assertNull(countError("1"))
        assertNull(countError("4"))
        assertNotNull(countError("0"))
        assertNull(countError("0", min = 0))
        assertNotNull(countError("10", max = 9))
    }

    @Test
    fun `percent is capped at one hundred`() {
        assertNull(percentError("0"))
        assertNull(percentError("100"))
        assertNull(percentError("99.5"))
        assertNotNull(percentError("101"))
        assertNotNull(percentError("-1"))
    }

    @Test
    fun `mac address accepts colon and hyphen forms`() {
        assertNull(macAddressError("AA:BB:CC:DD:EE:FF"))
        assertNull(macAddressError("aa-bb-cc-dd-ee-ff"))
        assertNull(macAddressError(" 00:11:22:33:44:55 "))
        assertNotNull(macAddressError("AA:BB:CC:DD:EE"))
        assertNotNull(macAddressError("AA:BB:CC:DD:EE:GG"))
        assertNotNull(macAddressError("AABBCCDDEEFF"))
        assertNotNull(macAddressError("zz"))
    }

    @Test
    fun `alert threshold rejects empty and non numeric instead of using eighty`() {
        assertNotNull(alertThresholdError("", "CPU Usage", MeasurementSystem.Metric))
        assertNotNull(alertThresholdError("abc", "CPU Usage", MeasurementSystem.Metric))
    }

    @Test
    fun `alert threshold caps percentage metrics at one hundred`() {
        assertNull(alertThresholdError("90", "CPU Usage", MeasurementSystem.Metric))
        assertNull(alertThresholdError("100", "Memory Usage", MeasurementSystem.Metric))
        assertNotNull(alertThresholdError("101", "Disk Usage", MeasurementSystem.Metric))
        assertNotNull(alertThresholdError("-1", "CPU Usage", MeasurementSystem.Metric))
    }

    @Test
    fun `alert threshold requires positive latency`() {
        assertNull(alertThresholdError("250", "Latency", MeasurementSystem.Metric))
        assertNotNull(alertThresholdError("0", "Latency", MeasurementSystem.Metric))
    }

    @Test
    fun `percentage cap is not unit converted`() {
        // A percentage is unitless: switching to Imperial must not change its bounds.
        assertNull(alertThresholdError("100", "CPU Usage", MeasurementSystem.Imperial))
        assertNotNull(alertThresholdError("101", "CPU Usage", MeasurementSystem.Imperial))
    }

    @Test
    fun `temperature bound honours the measurement system`() {
        // Ordinary values are fine in whichever unit is displayed.
        assertNull(alertThresholdError("80", "Temperature", MeasurementSystem.Metric))
        assertNull(alertThresholdError("176", "Temperature", MeasurementSystem.Imperial))

        // Absolute zero is -273.15C == -459.67F: the floor must hold in both units.
        assertNotNull(alertThresholdError("-300", "Temperature", MeasurementSystem.Metric))
        assertNotNull(alertThresholdError("-460", "Temperature", MeasurementSystem.Imperial))

        // -300F is about -184C, which is absurd but physically valid, so it is not rejected here.
        assertNull(alertThresholdError("-300", "Temperature", MeasurementSystem.Imperial))
    }

    @Test
    fun `temperature error messages do not leak the wrong unit`() {
        // Imperial 80F is ~26.7C: valid, so no message at all.
        assertEquals(null, alertThresholdError("80", "Temperature", MeasurementSystem.Imperial))
    }
}
