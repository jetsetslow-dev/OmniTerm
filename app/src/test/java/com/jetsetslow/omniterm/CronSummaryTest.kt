package com.jetsetslow.omniterm

import com.jetsetslow.omniterm.ui.cronSummary
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * The CRON tab labels each entry with what its schedule means. It used to recognise only the four
 * presets the screen itself can create, so anything written by hand -- by far the common case on a
 * real server -- was labelled "Custom schedule": a name that describes nothing, shown next to a
 * Delete button.
 */
class CronSummaryTest {

    @Test
    fun `the four presets still read as themselves`() {
        assertEquals("Every hour", cronSummary("0 * * * *"))
        assertEquals("Every day at 02:00", cronSummary("0 2 * * *"))
        assertEquals("Every Sunday at 02:00", cronSummary("0 2 * * 0"))
        assertEquals("Monthly on day 1 at 02:00", cronSummary("0 2 1 * *"))
    }

    @Test
    fun `the shapes people actually write are described`() {
        assertEquals("Every 5 minutes", cronSummary("*/5 * * * *"))
        assertEquals("Every minute", cronSummary("* * * * *"))
        assertEquals("Every hour at 30 past", cronSummary("30 * * * *"))
        assertEquals("Every 6 hours, at 00 past", cronSummary("0 */6 * * *"))
        assertEquals("Every weekday at 07:30", cronSummary("30 7 * * 1-5"))
        assertEquals("Every Saturday at 09:00", cronSummary("0 9 * * 6"))
    }

    @Test
    fun `shorthands say what they do`() {
        assertEquals("At every boot", cronSummary("@reboot"))
        assertEquals("Every day at 00:00", cronSummary("@daily"))
        assertEquals("Every hour", cronSummary("@hourly"))
    }

    @Test
    fun `something genuinely unusual is admitted as unusual`() {
        // Better than a confident wrong sentence about when someone's job will run.
        assertEquals("Custom schedule", cronSummary("0 0 1,15 */2 3"))
        assertEquals("Custom schedule", cronSummary("gibberish"))
        assertEquals("Custom schedule", cronSummary("0 2 * *"))
    }
}
