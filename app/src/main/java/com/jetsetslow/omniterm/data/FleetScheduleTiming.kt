package com.jetsetslow.omniterm.data

import java.time.Instant
import java.time.LocalTime
import java.time.ZoneId
import java.time.ZonedDateTime

/**
 * When a [FleetScheduleEntity] runs next. A run that Android holds back while the phone sleeps
 * runs late, once; the one after it is counted from when it ran, so missed runs are not made up.
 */
object FleetScheduleTiming {
    const val EVERY = "every"
    const val DAILY = "daily"
    const val WEEKLY = "weekly"
    val REPEATS = listOf(EVERY, DAILY, WEEKLY)

    /** The intervals offered: Android runs background work at most about every 15 minutes. */
    val EVERY_MINUTES = listOf(15, 30, 60, 120, 360, 720)

    private val TIME = Regex("""([01]?\d|2[0-3]):([0-5]\d)""")

    /** A 24-hour time typed as H:MM or HH:MM, as minutes after midnight; null for anything else. */
    fun parseTime(text: String): Int? = TIME.matchEntire(text.trim())?.destructured?.let { (h, m) -> h.toInt() * 60 + m.toInt() }

    /** [minuteOfDay] as HH:MM. */
    fun formatTime(minuteOfDay: Int): String = minuteOfDay.coerceIn(0, 24 * 60 - 1).let { "%02d:%02d".format(java.util.Locale.ROOT, it / 60, it % 60) }

    /** The first time after [after] that [schedule] is due, in [zone]'s local time. */
    fun nextRun(schedule: FleetScheduleEntity, after: Long, zone: ZoneId = ZoneId.systemDefault()): Long = when (schedule.repeat) {
        EVERY -> after + schedule.everyMinutes.coerceIn(EVERY_MINUTES.first(), EVERY_MINUTES.last()) * 60_000L
        WEEKLY -> nextAt(after, zone, schedule.minuteOfDay, schedule.dayOfWeek.coerceIn(1, 7))
        else -> nextAt(after, zone, schedule.minuteOfDay, null)
    }

    /**
     * The next [minuteOfDay] after [after], on [dayOfWeek] when it is set. A time the clocks skip
     * is moved past the gap; a time they pass twice runs once, at the first.
     */
    private fun nextAt(after: Long, zone: ZoneId, minuteOfDay: Int, dayOfWeek: Int?): Long {
        val minute = minuteOfDay.coerceIn(0, 24 * 60 - 1)
        val time = LocalTime.of(minute / 60, minute % 60)
        var date = Instant.ofEpochMilli(after).atZone(zone).toLocalDate()
        repeat(8) {
            if (dayOfWeek == null || date.dayOfWeek.value == dayOfWeek) {
                val at = ZonedDateTime.of(date, time, zone).toInstant().toEpochMilli()
                if (at > after) return at
            }
            date = date.plusDays(1)
        }
        error("No day within a week matched")
    }
}
