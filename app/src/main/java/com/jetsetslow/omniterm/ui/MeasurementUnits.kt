package com.jetsetslow.omniterm.ui

import java.util.Locale

enum class MeasurementSystem(val settingValue: String) {
    Metric("metric"),
    Imperial("imperial");

    companion object {
        fun fromSetting(value: String?): MeasurementSystem =
            entries.firstOrNull { it.settingValue == value } ?: Metric
    }
}

internal fun celsiusToDisplay(celsius: Float, system: MeasurementSystem): Float =
    if (system == MeasurementSystem.Imperial) celsius * 9f / 5f + 32f else celsius

internal fun displayTemperatureToCelsius(value: Float, system: MeasurementSystem): Float =
    if (system == MeasurementSystem.Imperial) (value - 32f) * 5f / 9f else value

internal fun temperatureUnit(system: MeasurementSystem): String =
    if (system == MeasurementSystem.Imperial) "°F" else "°C"

internal fun formatTemperature(
    celsius: Float,
    system: MeasurementSystem,
    decimals: Int = 0,
): String {
    val value = celsiusToDisplay(celsius, system)
    return "%.${decimals}f%s".format(Locale.getDefault(), value, temperatureUnit(system))
}
