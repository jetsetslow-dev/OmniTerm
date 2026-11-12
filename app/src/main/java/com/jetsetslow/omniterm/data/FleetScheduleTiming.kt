package com.jetsetslow.omniterm.data

import java.util.TimeZone

/**
 * When a [FleetScheduleEntity] runs next. A run that Android holds back while the phone sleeps
 * runs late, once; the one after it is counted from when it ran, so missed runs are not made up.
 *
 * Local times are worked out with [TimeZone] alone, which every Android version the app runs on
 * has; java.time needs Android 8.
 */
object FleetScheduleTiming {
    const val EVERY = "every"
    const val DAILY = "daily"
    const val WEEKLY = "weekly"
    val REPEATS = listOf(EVERY, DAILY, WEEKLY)

    /** The intervals offered: Android runs background work at most about every 15 minutes. */
    val EVERY_MINUTES = listOf(15, 30, 60, 120, 360, 720)

    private val TIME = Regex("""([01]?\d|2[0-3]):([0-5]\d)""")
    private const val MINUTE_MS = 60_000L
    private const val DAY_MS = 24 * 60 * MINUTE_MS

    /** A 24-hour time typed as H:MM or HH:MM, as minutes after midnight; null for anything else. */
    fun parseTime(text: String): Int? = TIME.matchEntire(text.trim())?.destructured?.let { (h, m) -> h.toInt() * 60 + m.toInt() }

    /** [minuteOfDay] as HH:MM. */
    fun formatTime(minuteOfDay: Int): String = minuteOfDay.coerceIn(0, 24 * 60 - 1).let { "%02d:%02d".format(java.util.Locale.ROOT, it / 60, it % 60) }

    /** The first time after [after] that [schedule] is due, in [zone]'s local time. */
    fun nextRun(schedule: FleetScheduleEntity, after: Long, zone: TimeZone = TimeZone.getDefault()): Long = when (schedule.repeat) {
        EVERY -> after + schedule.everyMinutes.coerceIn(EVERY_MINUTES.first(), EVERY_MINUTES.last()) * MINUTE_MS
        WEEKLY -> nextAt(after, zone, schedule.minuteOfDay, schedule.dayOfWeek.coerceIn(1, 7))
        else -> nextAt(after, zone, schedule.minuteOfDay, null)
    }

    /**
     * The next [minuteOfDay] after [after], on [dayOfWeek] (1 Monday to 7 Sunday) when it is set. A
     * time the clocks skip is moved past the gap; a time they pass twice runs once, at the first.
     */
    private fun nextAt(after: Long, zone: TimeZone, minuteOfDay: Int, dayOfWeek: Int?): Long {
        val minute = minuteOfDay.coerceIn(0, 24 * 60 - 1)
        // Days counted from 1 January 1970 in local time; that day was a Thursday (4).
        val today = (after + zone.getOffset(after)).floorDiv(DAY_MS)
        for (day in today..today + 7) {
            if (dayOfWeek != null && (day + 3).mod(7) + 1 != dayOfWeek) continue
            val at = instantOf(day * DAY_MS + minute * MINUTE_MS, zone)
            if (at > after) return at
        }
        error("No day within a week matched")
    }

    /**
     * The instant [zone]'s clocks show [wall] (local time, as milliseconds from the epoch as if it
     * were UTC). In a repeated hour, the first; in a skipped one, the offset from before the change
     * applies, which moves the time past the gap. java.time does the same.
     */
    private fun instantOf(wall: Long, zone: TimeZone): Long {
        val before = wall - zone.getOffset(wall - DAY_MS)
        val after = wall - zone.getOffset(wall + DAY_MS)
        val valid = listOf(before, after).filter { it + zone.getOffset(it) == wall }
        return valid.minOrNull() ?: before
    }
}
