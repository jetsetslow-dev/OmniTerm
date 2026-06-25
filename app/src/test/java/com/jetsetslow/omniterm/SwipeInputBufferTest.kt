package com.jetsetslow.omniterm

import com.jetsetslow.omniterm.ui.SwipeInputBuffer
import org.junit.Assert.assertEquals
import org.junit.Test

/** Deterministic unit tests for the pure smart-swipe IME word buffer. No Android deps. */
class SwipeInputBufferTest {

    @Test
    fun `in-progress word is held, not emitted`() {
        val b = SwipeInputBuffer()
        val r = b.onValue("hel")
        assertEquals("", r.emit)
        assertEquals("hel", r.fieldText)
        assertEquals("hel", b.pendingWord)
    }

    @Test
    fun `same-word correction replaces the held word without emitting`() {
        val b = SwipeInputBuffer()
        b.onValue("teh")
        val r = b.onValue("the") // keyboard autocorrects in place
        assertEquals("", r.emit)
        assertEquals("the", r.fieldText)
    }

    @Test
    fun `a trailing space flushes the word with its single space`() {
        val b = SwipeInputBuffer()
        b.onValue("ls")
        val r = b.onValue("ls ") // keyboard supplies its own inter-word space
        assertEquals("ls ", r.emit)
        assertEquals("", r.fieldText)
        assertEquals("", b.pendingWord)
    }

    @Test
    fun `no double space is ever injected when the keyboard adds its own`() {
        val b = SwipeInputBuffer()
        // Two swiped words where the keyboard auto-spaces between them in one accumulating field.
        b.onValue("git")
        val r = b.onValue("git ")
        assertEquals("git ", r.emit) // exactly one space, the keyboard's own
        val r2 = b.onValue("status")
        assertEquals("", r2.emit)
        assertEquals("status", r2.fieldText)
    }

    @Test
    fun `in-place autocorrect replacement does not emit the pre-correction word`() {
        val b = SwipeInputBuffer()
        b.onValue("teh")
        // Autocorrect replaces the whole field; it shares no prefix with "teh" but must NOT be
        // treated as a new word (that would emit the uncorrected "teh").
        val r = b.onValue("the")
        assertEquals("", r.emit)
        assertEquals("the", r.fieldText)
    }

    @Test
    fun `punctuation in the value flushes everything up to and including it`() {
        val b = SwipeInputBuffer()
        b.onValue("cd")
        val r = b.onValue("cd/") // '/' is a separator
        assertEquals("cd/", r.emit)
        assertEquals("", r.fieldText)
    }

    @Test
    fun `empty value resets the held word`() {
        val b = SwipeInputBuffer()
        b.onValue("abc")
        val r = b.onValue("")
        assertEquals("", r.emit)
        assertEquals("", r.fieldText)
        assertEquals("", b.pendingWord)
    }

    @Test
    fun `flushBare emits the held word with no separator`() {
        val b = SwipeInputBuffer()
        b.onValue("whoami")
        assertEquals("whoami", b.flushBare())
        assertEquals("", b.pendingWord)
        assertEquals("", b.flushBare()) // nothing left
    }

    @Test
    fun `reset abandons the held word so it cannot leak across a boundary`() {
        val b = SwipeInputBuffer()
        b.onValue("rm")
        b.reset()
        assertEquals("", b.pendingWord)
        // A following word starts clean — no stray "rm" prefix.
        val r = b.onValue("ls")
        assertEquals("", r.emit)
        assertEquals("ls", r.fieldText)
    }

    @Test
    fun `extending a held word does not re-emit the shared prefix`() {
        val b = SwipeInputBuffer()
        b.onValue("data") // held
        val r = b.onValue("database") // continuation: same word growing
        assertEquals("", r.emit)
        assertEquals("database", r.fieldText)
    }
}
