package com.jetsetslow.omniterm

import com.jetsetslow.omniterm.data.FleetScheduleEntity
import com.jetsetslow.omniterm.data.FleetScheduleTiming
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import java.time.LocalDateTime
import java.time.ZoneId
import java.time.ZonedDateTime
import java.util.TimeZone

/** When a schedule runs next, in the phone's local time, through the clock changes too. */
class FleetScheduleTimingTest {
    private val london = ZoneId.of("Europe/London")

    @Test
    fun anIntervalCountsFromTheLastRunWithinWhatAndroidAllows() {
        val after = at(2026, 11, 10, 9, 7)
        assertEquals(after + 30 * MINUTE, next(every(30), after))
        assertEquals("Android runs background work at most about every 15 minutes", after + 15 * MINUTE, next(every(5), after))
        assertEquals(after + 720 * MINUTE, next(every(5000), after))
    }

    @Test
    fun aDailyTimeIsTheNextOneStrictlyAfter() {
        assertEquals(at(2026, 11, 10, 3, 0), next(daily(3 * 60), at(2026, 11, 10, 2, 0)))
        assertEquals("a run at 03:00 is next due tomorrow", at(2026, 11, 11, 3, 0), next(daily(3 * 60), at(2026, 11, 10, 3, 0)))
        assertEquals(at(2026, 11, 11, 3, 0), next(daily(3 * 60), at(2026, 11, 10, 3, 1)))
    }

    @Test
    fun aWeeklyTimeWaitsForItsDay() {
        // 10 November 2026 is a Tuesday.
        assertEquals(at(2026, 11, 16, 3, 0), next(weekly(1, 3 * 60), at(2026, 11, 10, 12, 0)))
        assertEquals(at(2026, 11, 10, 18, 30), next(weekly(2, 18 * 60 + 30), at(2026, 11, 10, 12, 0)))
        assertEquals("the same day once its time has passed is a week on", at(2026, 11, 17, 3, 0), next(weekly(2, 3 * 60), at(2026, 11, 10, 3, 0)))
    }

    @Test
    fun aTimeTheClocksSkipRunsJustAfterAndOneTheyRepeatRunsOnce() {
        // 29 March 2026: London's clocks go from 01:00 to 02:00, so 01:30 never happens.
        val skipped = next(daily(90), at(2026, 3, 29, 0, 30))
        assertEquals(ZonedDateTime.of(LocalDateTime.of(2026, 3, 29, 2, 30), london).toInstant().toEpochMilli(), skipped)
        // 25 October 2026: 01:30 happens twice; it runs at the first, and next on the 26th.
        val first = next(daily(90), at(2026, 10, 25, 0, 30))
        assertEquals(ZonedDateTime.ofLocal(LocalDateTime.of(2026, 10, 25, 1, 30), london, null).withEarlierOffsetAtOverlap().toInstant().toEpochMilli(), first)
        assertEquals(ZonedDateTime.of(LocalDateTime.of(2026, 10, 26, 1, 30), london).toInstant().toEpochMilli(), next(daily(90), first))
    }

    @Test
    fun aTimeIsTypedAsHoursAndMinutes() {
        assertEquals(185, FleetScheduleTiming.parseTime("3:05"))
        assertEquals(185, FleetScheduleTiming.parseTime(" 03:05 "))
        assertEquals(1439, FleetScheduleTiming.parseTime("23:59"))
        assertNull(FleetScheduleTiming.parseTime("24:00"))
        assertNull(FleetScheduleTiming.parseTime("7"))
        assertNull(FleetScheduleTiming.parseTime("07:60"))
        assertEquals("03:05", FleetScheduleTiming.formatTime(185))
        assertEquals("00:00", FleetScheduleTiming.formatTime(0))
    }

    private fun next(schedule: FleetScheduleEntity, after: Long) = FleetScheduleTiming.nextRun(schedule, after, TimeZone.getTimeZone(london))

    private fun at(year: Int, month: Int, day: Int, hour: Int, minute: Int): Long =
        ZonedDateTime.of(LocalDateTime.of(year, month, day, hour, minute), london).toInstant().toEpochMilli()

    private fun every(minutes: Int) = base().copy(repeat = FleetScheduleTiming.EVERY, everyMinutes = minutes)
    private fun daily(minuteOfDay: Int) = base().copy(repeat = FleetScheduleTiming.DAILY, minuteOfDay = minuteOfDay)
    private fun weekly(day: Int, minuteOfDay: Int) = base().copy(repeat = FleetScheduleTiming.WEEKLY, dayOfWeek = day, minuteOfDay = minuteOfDay)
    private fun base() = FleetScheduleEntity(name = "nightly", scriptId = 1, mode = "Servers")

    private companion object {
        const val MINUTE = 60_000L
    }
}
