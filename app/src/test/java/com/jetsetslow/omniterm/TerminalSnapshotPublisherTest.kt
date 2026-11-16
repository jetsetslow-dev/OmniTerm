package com.jetsetslow.omniterm

import com.jetsetslow.omniterm.ui.TerminalSnapshotPublisher
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The terminal shows the last chunk of a burst of output even when nothing follows it. A TUI such as
 * Claude Code or Codex sends its final frame and goes quiet; a dropped last update left its screen
 * half drawn until the keyboard was toggled. Virtual time: no real time passes.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class TerminalSnapshotPublisherTest {

    /** Chunks fed to a pretend emulator, and what each publish showed. */
    private class Screen {
        var fed = 0
        val shown = mutableListOf<Int>()
        val shownAt = mutableListOf<Long>()
    }

    private fun TestScope.publisher(screen: Screen, onPublish: () -> Unit = {}) =
        TerminalSnapshotPublisher(backgroundScope, nowMs = { testScheduler.currentTime }) {
            screen.shown += screen.fed
            screen.shownAt += testScheduler.currentTime
            onPublish()
        }

    /**
     * Lets the publisher finish its pending work. It runs in the background scope, whose delayed
     * tasks advanceUntilIdle() does not wait for, so time is moved on instead.
     */
    private fun TestScope.settle() {
        advanceTimeBy(1_000)
        runCurrent()
    }

    @Test
    fun aChunkFedWhileTheDelayedPublishRunsIsShownLater() = runTest(StandardTestDispatcher()) {
        val screen = Screen()
        lateinit var publisher: TerminalSnapshotPublisher
        var raced = false
        publisher = publisher(screen) {
            // The reader feeds the last chunk just after this publish took its snapshot.
            if (testScheduler.currentTime == 16L && !raced) {
                raced = true
                screen.fed++
                publisher.markDirty()
            }
        }
        screen.fed++; publisher.markDirty()            // t=0
        runCurrent()
        advanceTimeBy(5); screen.fed++; publisher.markDirty() // t=5: within the interval
        settle()

        assertTrue("the race happened", raced)
        assertEquals("the last chunk is on screen", 3, screen.shown.last())
    }

    @Test
    fun theFirstChunkAfterQuietShowsAtOnce() = runTest(StandardTestDispatcher()) {
        val screen = Screen()
        val publisher = publisher(screen)
        advanceTimeBy(1_000)
        screen.fed++; publisher.markDirty()
        runCurrent()
        assertEquals(listOf(1), screen.shown)
        assertEquals(listOf(1_000L), screen.shownAt)
    }

    @Test
    fun aBurstPublishesAtMostOncePerIntervalAndEndsOnItsLastChunk() = runTest(StandardTestDispatcher()) {
        val screen = Screen()
        val publisher = publisher(screen)
        // 1,000 chunks, one every 0.1 ms of virtual time for 100 ms.
        repeat(1_000) { i ->
            screen.fed++; publisher.markDirty()
            if (i % 10 == 9) advanceTimeBy(1) else runCurrent()
        }
        settle()
        assertEquals(1_000, screen.shown.last())
        assertTrue("published ${screen.shown.size} times", screen.shown.size <= 100 / 16 + 2)
        screen.shownAt.zipWithNext().forEach { (a, b) -> assertTrue("$a then $b", b - a >= 16) }
    }

    @Test
    fun chunksDuringTheWaitShareOnePublish() = runTest(StandardTestDispatcher()) {
        val screen = Screen()
        val publisher = publisher(screen)
        screen.fed++; publisher.markDirty()
        runCurrent()
        repeat(5) { advanceTimeBy(2); screen.fed++; publisher.markDirty() }
        settle()
        assertEquals(listOf(1, 6), screen.shown)
        assertEquals(listOf(0L, 16L), screen.shownAt)
    }

    @Test
    fun stoppedPublishesNothingMore() = runTest(StandardTestDispatcher()) {
        val screen = Screen()
        val publisher = publisher(screen)
        screen.fed++; publisher.markDirty()
        runCurrent()
        advanceTimeBy(3); screen.fed++; publisher.markDirty()
        publisher.stop()
        publisher.markDirty()
        settle()
        assertEquals(listOf(1), screen.shown)
    }
}
