package com.jetsetslow.omniterm

import com.jetsetslow.omniterm.ui.OperationGeneration
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class OperationGenerationTest {
    @Test
    fun newerRequestInvalidatesOlderCompletionForSameKey() {
        val generations = OperationGeneration<Int>()
        val first = generations.begin(listOf(7)).getValue(7)
        val second = generations.begin(listOf(7)).getValue(7)

        assertFalse(generations.isCurrent(7, first))
        assertTrue(generations.isCurrent(7, second))
    }

    @Test
    fun independentKeysDoNotInvalidateEachOther() {
        val generations = OperationGeneration<Int>()
        val first = generations.begin(listOf(7, 9))
        generations.begin(listOf(7))

        assertFalse(generations.isCurrent(7, first.getValue(7)))
        assertTrue(generations.isCurrent(9, first.getValue(9)))
    }

    @Test
    fun forgottenKeyCannotPublishAnInFlightCompletion() {
        val generations = OperationGeneration<Int>()
        val generation = generations.begin(listOf(7)).getValue(7)
        generations.forget(listOf(7))

        assertFalse(generations.isCurrent(7, generation))
    }

    @Test
    fun staleGenerationCannotRunPublication() {
        val generations = OperationGeneration<Int>()
        val stale = generations.begin(listOf(7)).getValue(7)
        generations.begin(listOf(7))
        var published = false

        val accepted = generations.publishIfCurrent(7, stale) { published = true }

        assertFalse(accepted)
        assertFalse(published)
    }
}
