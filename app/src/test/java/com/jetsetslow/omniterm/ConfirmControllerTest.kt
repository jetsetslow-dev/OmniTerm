package com.jetsetslow.omniterm

import android.content.res.Resources
import com.jetsetslow.omniterm.ui.ConfirmController
import io.mockk.every
import io.mockk.mockk
import org.junit.Assert.*
import org.junit.Test

class ConfirmControllerTest {
    @Test fun confirmationCompletesOnceWithoutReportingCancellation() {
        val controller = ConfirmController()
        var confirmed = 0
        var cancelled = 0
        controller.ask("Restore", "Fixture", onCancel = { cancelled++ }) { confirmed++ }
        controller.confirm()
        controller.confirm()
        controller.dismiss()
        assertEquals(1, confirmed)
        assertEquals(0, cancelled)
        assertNull(controller.pending)
    }

    @Test fun dismissalReportsCancellationOnceWithoutRunningTheAction() {
        val controller = ConfirmController()
        var confirmed = 0
        var cancelled = 0
        controller.ask("Restore", "Fixture", onCancel = { cancelled++ }) { confirmed++ }
        controller.dismiss()
        controller.dismiss()
        controller.confirm()
        assertEquals(0, confirmed)
        assertEquals(1, cancelled)
        assertNull(controller.pending)
    }

    @Test fun completionClearsTheOldRequestBeforeACallbackQueuesAnother() {
        val controller = ConfirmController()
        controller.ask("First", "Fixture") {
            assertNull(controller.pending)
            controller.ask("Second", "Fixture") {}
        }
        controller.confirm()
        assertEquals("Second", controller.pending?.title)
        controller.dismiss()
        assertNull(controller.pending)
    }

    @Test fun cancellationClearsTheOldRequestBeforeACallbackQueuesAnother() {
        val controller = ConfirmController()
        controller.ask("First", "Fixture", onCancel = {
            assertNull(controller.pending)
            controller.ask("Second", "Fixture") {}
        }) { fail("A cancelled action must not run") }
        controller.dismiss()
        assertEquals("Second", controller.pending?.title)
    }

    // Confirmations are queued from click handlers, where stringResource is unavailable, so their
    // text comes from the resources rememberConfirm() hands the controller.
    @Test fun strFormatsThroughTheScreensResources() {
        val controller = ConfirmController()
        val resources = mockk<Resources>()
        every { resources.getString(42, "notes.txt") } returns "Delete notes.txt?"
        controller.resources = resources
        assertEquals("Delete notes.txt?", controller.str(42, "notes.txt"))
    }

    @Test fun strWithoutRememberConfirmFailsLoudly() {
        val error = assertThrows(IllegalStateException::class.java) { ConfirmController().str(42) }
        assertTrue(error.message!!.contains("rememberConfirm"))
    }
}
