package com.jetsetslow.omniterm

import com.jetsetslow.omniterm.data.HealthScoringConfig
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class HealthScoringTest {

    @Test
    fun defaultScoreDeductsPerTier() {
        val c = HealthScoringConfig.DEFAULT
        // CPU 95 (critical -30), MEM 40 (none), disk 40 (none), latency 10 (none) → 70.
        assertEquals(70, c.score(95f, 40f, 40f, 10))
        // Healthy host: full marks.
        assertEquals(100, c.score(10f, 20f, 30f, 5))
    }

    @Test
    fun breakdownListsOnlyDeductingFactors() {
        val c = HealthScoringConfig.DEFAULT
        val b = c.breakdown(cpu = 95f, ram = 85f, disk = 10f, rtt = 5, online = true)
        // CPU critical (-30) and Memory high (-12) deduct; disk & latency don't.
        assertEquals(2, b.factors.size)
        assertEquals(58, b.score)
        assertFalse(b.offline)
        assertTrue(b.factors.any { it.label.startsWith("CPU") && it.penalty == 30 })
        assertTrue(b.factors.any { it.label.startsWith("Memory") && it.penalty == 12 })
    }

    @Test
    fun offlineForcesZero() {
        val b = HealthScoringConfig.DEFAULT.breakdown(0f, 0f, 0f, 0, online = false)
        assertTrue(b.offline)
        assertEquals(0, b.score)
    }

    @Test
    fun encodeDecodeRoundTrips() {
        val custom = HealthScoringConfig().copy(
            cpu = HealthScoringConfig.DEFAULT.cpu.copy(criticalPenalty = 40)
        )
        val decoded = HealthScoringConfig.decode(custom.encode())
        assertEquals(custom, decoded)
        // Blank/garbage decode falls back to defaults rather than throwing.
        assertEquals(HealthScoringConfig.DEFAULT, HealthScoringConfig.decode(null))
        assertEquals(HealthScoringConfig.DEFAULT, HealthScoringConfig.decode("nonsense"))
    }
}
