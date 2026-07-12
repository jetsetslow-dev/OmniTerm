package com.jetsetslow.omniterm.data.ssh

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class SshLifecycleGenerationTest {
    @Test
    fun `stop during tunnel publication rolls publication back`() {
        val generation = TunnelGeneration()
        val expected = generation.snapshot()
        var published = false
        var rolledBack = false

        val accepted = generation.publishIfCurrent(
            expected = expected,
            publish = {
                published = true
                // Deterministically model stop() landing after the first check but before publish
                // returns to its caller.
                generation.invalidate()
            },
            rollback = {
                published = false
                rolledBack = true
            },
        )

        assertFalse(accepted)
        assertFalse(published)
        assertTrue(rolledBack)
    }

    @Test
    fun `stale tunnel generation never publishes`() {
        val generation = TunnelGeneration()
        val stale = generation.snapshot()
        generation.invalidate()
        var published = false

        assertFalse(generation.publishIfCurrent(stale, { published = true }, {}))
        assertFalse(published)
    }

    @Test
    fun `pool reset retires only entries created before reset`() {
        val resetGeneration = 7L

        assertTrue(entryPredatesReset(entryGeneration = 6L, resetGeneration = resetGeneration))
        assertFalse(entryPredatesReset(entryGeneration = 7L, resetGeneration = resetGeneration))
        assertFalse(entryPredatesReset(entryGeneration = 8L, resetGeneration = resetGeneration))
    }
}
