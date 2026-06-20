package com.jetsetslow.omniterm

import com.jetsetslow.omniterm.ui.displayTmuxSessionName
import com.jetsetslow.omniterm.ui.generateTmuxSessionName
import com.jetsetslow.omniterm.ui.generateUniqueTmuxSessionName
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.random.Random

class TmuxSessionNameTest {

    @Test
    fun generatedTmuxNamesAreReadableAndShellSafe() {
        repeat(100) { seed ->
            val name = generateTmuxSessionName(Random(seed))

            assertTrue(name.startsWith("omniterm-"))
            assertTrue(name.matches(Regex("[a-z-]+")))
            assertFalse(name.any { it.isDigit() })
            assertFalse(displayTmuxSessionName(name).contains("omniterm"))
        }
    }

    @Test
    fun uniqueGeneratorSkipsExistingNameForSameHost() {
        val random = Random(7)
        val first = generateTmuxSessionName(Random(7))

        val next = generateUniqueTmuxSessionName(setOf(first), random)

        assertTrue(next.startsWith("omniterm-"))
        assertTrue(next.matches(Regex("[a-z-]+")))
        assertFalse(next.any { it.isDigit() })
        assertTrue(next != first)
    }

    @Test
    fun existingNamesAreCallerScoped() {
        val first = generateTmuxSessionName(Random(7))
        val next = generateUniqueTmuxSessionName(emptySet(), Random(7))

        assertTrue(next == first)
    }
}
