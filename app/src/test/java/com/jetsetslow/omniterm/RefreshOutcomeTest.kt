package com.jetsetslow.omniterm

import com.jetsetslow.omniterm.data.RefreshHostState
import com.jetsetslow.omniterm.data.RefreshOutcome
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * A pull-to-refresh that ends badly has to say so. The regression this guards is a host left on the
 * "Checking host…" spinner forever: the refresh reported nothing at all, so the app looked broken
 * while the host was merely slow to answer.
 */
class RefreshOutcomeTest {

    private fun host(
        name: String = "atlas",
        status: String = "online",
        probed: Boolean = true,
        authStatus: String = "ok",
        authError: String? = null,
    ) = RefreshHostState(name, status, probed, authStatus, authError)

    @Test
    fun `a healthy fleet reports nothing`() {
        assertNull(RefreshOutcome.describe(listOf(host(), host(name = "beta")), 30))
    }

    @Test
    fun `no hosts reports nothing`() {
        assertNull(RefreshOutcome.describe(emptyList(), 30))
    }

    @Test
    fun `a host still marked connecting is reported, not left silent`() {
        val message = RefreshOutcome.describe(listOf(host(status = "connecting")), 30)
        assertEquals("Refresh problem on 1 host(s): atlas is still not answering after 30s", message)
    }

    @Test
    fun `a host that never completed a probe is reported even when the row says online`() {
        // This is the exact stranding: the status column is not "connecting" but the row still
        // renders the spinner because no probe ever reached a verdict for it.
        assertTrue(RefreshOutcome.isStillChecking(host(status = "online", probed = false)))
        val message = RefreshOutcome.describe(listOf(host(status = "online", probed = false)), 30)
        assertEquals("Refresh problem on 1 host(s): atlas is still not answering after 30s", message)
    }

    @Test
    fun `an offline host is reported as not responding on its route`() {
        assertEquals(
            "Refresh problem on 1 host(s): atlas did not respond on its configured SSH route",
            RefreshOutcome.describe(listOf(host(status = "offline")), 30),
        )
    }

    @Test
    fun `an auth failure surfaces the classified error`() {
        assertEquals(
            "Refresh problem on 1 host(s): atlas: Permission denied (publickey).",
            RefreshOutcome.describe(
                listOf(host(authStatus = "failed", authError = "Permission denied (publickey).")),
                30,
            ),
        )
    }

    @Test
    fun `an auth failure with no message still says something useful`() {
        assertEquals(
            "Refresh problem on 1 host(s): atlas: SSH authentication failed.",
            RefreshOutcome.describe(listOf(host(authStatus = "failed", authError = null)), 30),
        )
    }

    @Test
    fun `still-checking wins over a stale auth failure on the same host`() {
        // Reporting a previous cycle's auth error for a host we could not check this time would be
        // a guess. "Still not answering" is what actually happened.
        assertEquals(
            "Refresh problem on 1 host(s): atlas is still not answering after 30s",
            RefreshOutcome.describe(
                listOf(host(status = "connecting", authStatus = "failed", authError = "old error")),
                30,
            ),
        )
    }

    @Test
    fun `every failing host is named and counted`() {
        val message = RefreshOutcome.describe(
            listOf(
                host(name = "good"),
                host(name = "slow", status = "connecting"),
                host(name = "down", status = "offline"),
            ),
            30,
        )
        assertEquals(
            "Refresh problem on 2 host(s): slow is still not answering after 30s; " +
                "down did not respond on its configured SSH route",
            message,
        )
    }
}
