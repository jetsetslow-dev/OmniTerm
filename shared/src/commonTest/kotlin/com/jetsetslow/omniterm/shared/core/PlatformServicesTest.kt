package com.jetsetslow.omniterm.shared.core

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class PlatformServicesTest {
    @Test
    fun deterministicServicesNeedNoPlatformGlobals() {
        val clock = WallClock { 1234L }
        val ids = ArrayDeque(listOf("one", "two"))
        val generator = IdGenerator { ids.removeFirst() }
        assertEquals(1234L, clock.nowEpochMillis())
        assertEquals("one", generator.nextId())
        assertEquals("two", generator.nextId())
    }

    @Test
    fun operationGenerationRejectsOldOwners() {
        val generation = OperationGeneration()
        val first = generation.next()
        val second = generation.next()
        assertFalse(generation.isCurrent(first))
        assertTrue(generation.isCurrent(second))
    }
}
