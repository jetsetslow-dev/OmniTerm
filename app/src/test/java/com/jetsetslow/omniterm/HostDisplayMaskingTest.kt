package com.jetsetslow.omniterm

import com.jetsetslow.omniterm.data.ServerEntity
import com.jetsetslow.omniterm.ui.HostDisplay
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Test

/**
 * Guards the "Hide sensitive info" contract. Screens must render addresses through [HostDisplay];
 * rendering a raw `.host`/`.address` bypasses the toggle and leaks an IP on a shared screen. Four
 * such leaks shipped in #47 (backup host list, duplicate-host dialog, trusted host-key list and its
 * remove-confirm dialog), so these assertions pin the masking primitives those call sites now use.
 */
class HostDisplayMaskingTest {

    private val server = ServerEntity(
        id = 1,
        name = "prod-web",
        host = "192.168.1.50",
        username = "root",
    )

    @After
    fun reset() {
        HostDisplay.hideSensitiveInfo = false
    }

    @Test
    fun addressesAreVisibleWhenHidingIsOff() {
        HostDisplay.hideSensitiveInfo = false
        assertEquals("192.168.1.50", HostDisplay.host(server))
        assertEquals("root@192.168.1.50", HostDisplay.userAtHost(server))
        assertEquals("10.0.0.9", HostDisplay.sensitive("10.0.0.9"))
    }

    @Test
    fun serverAddressesFallBackToTheUserGivenName() {
        HostDisplay.hideSensitiveInfo = true
        assertEquals("prod-web", HostDisplay.host(server))
        assertEquals("root@prod-web", HostDisplay.userAtHost(server))
    }

    /** The duplicate-host dialog interpolates both of these; neither may reveal the address. */
    @Test
    fun duplicateHostDialogTextLeaksNothing() {
        HostDisplay.hideSensitiveInfo = true
        val rendered = "Host ${HostDisplay.name(server)} already uses ${HostDisplay.host(server)}."
        assertFalse("Raw address leaked: $rendered", rendered.contains("192.168.1.50"))
    }

    /**
     * Trusted host keys and backup host rows have no name to substitute in address position (a
     * KnownHost carries only host/keyType/fingerprint), so they mask outright instead.
     */
    @Test
    fun valuesWithoutANameAreMaskedOutright() {
        HostDisplay.hideSensitiveInfo = true
        assertEquals("•••", HostDisplay.sensitive("192.168.1.50"))
        assertFalse(HostDisplay.sensitive("192.168.1.50").contains("192.168"))
    }

    /** A server saved without a name must still never fall back to showing its address. */
    @Test
    fun blankNamesDoNotFallBackToTheAddress() {
        HostDisplay.hideSensitiveInfo = true
        val unnamed = server.copy(name = "")
        assertFalse(HostDisplay.host(unnamed).contains("192.168.1.50"))
        assertFalse(HostDisplay.name(unnamed).contains("192.168.1.50"))
    }
}
