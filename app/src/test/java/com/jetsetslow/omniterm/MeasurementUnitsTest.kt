package com.jetsetslow.omniterm

import com.jetsetslow.omniterm.ui.MeasurementSystem
import com.jetsetslow.omniterm.ui.celsiusToDisplay
import com.jetsetslow.omniterm.ui.displayTemperatureToCelsius
import com.jetsetslow.omniterm.ui.formatTemperature
import com.jetsetslow.omniterm.ui.temperatureUnit
import java.util.Locale
import org.junit.Assert.assertEquals
import org.junit.Test

class MeasurementUnitsTest {
    @Test
    fun imperialTemperatureRoundTripsThroughCanonicalCelsiusStorage() {
        val fahrenheit = celsiusToDisplay(65f, MeasurementSystem.Imperial)

        assertEquals(149f, fahrenheit, 0.001f)
        assertEquals(
            65f,
            displayTemperatureToCelsius(fahrenheit, MeasurementSystem.Imperial),
            0.001f,
        )
    }

    @Test
    fun temperatureFormattingUsesSelectedMeasurementSystem() {
        val previous = Locale.getDefault()
        try {
            Locale.setDefault(Locale.US)
            assertEquals("75.0°C", formatTemperature(75f, MeasurementSystem.Metric, decimals = 1))
            assertEquals("167.0°F", formatTemperature(75f, MeasurementSystem.Imperial, decimals = 1))
            assertEquals("°F", temperatureUnit(MeasurementSystem.Imperial))
        } finally {
            Locale.setDefault(previous)
        }
    }
}
