package com.jetsetslow.omniterm.ui

import kotlin.math.abs
import kotlin.math.roundToLong

enum class MeasurementSystem(val settingValue: String) {
    Metric("metric"),
    Imperial("imperial");

    companion object {
        fun fromSetting(value: String?): MeasurementSystem =
            entries.firstOrNull { it.settingValue == value } ?: Metric
    }
}

fun celsiusToDisplay(celsius: Float, system: MeasurementSystem): Float =
    if (system == MeasurementSystem.Imperial) celsius * 9f / 5f + 32f else celsius

fun displayTemperatureToCelsius(value: Float, system: MeasurementSystem): Float =
    if (system == MeasurementSystem.Imperial) (value - 32f) * 5f / 9f else value

fun temperatureUnit(system: MeasurementSystem): String =
    if (system == MeasurementSystem.Imperial) "°F" else "°C"

fun formatTemperature(
    celsius: Float,
    system: MeasurementSystem,
    decimals: Int = 0,
): String {
    val value = celsiusToDisplay(celsius, system)
    return formatFixed(value, decimals) + temperatureUnit(system)
}

private fun formatFixed(value: Float, decimals: Int): String {
    val places = decimals.coerceIn(0, 6)
    var factor = 1L
    repeat(places) { factor *= 10L }
    val scaled = (value.toDouble() * factor).roundToLong()
    if (places == 0) return scaled.toString()
    val sign = if (scaled < 0) "-" else ""
    val magnitude = abs(scaled)
    return "$sign${magnitude / factor}.${(magnitude % factor).toString().padStart(places, '0')}"
}
