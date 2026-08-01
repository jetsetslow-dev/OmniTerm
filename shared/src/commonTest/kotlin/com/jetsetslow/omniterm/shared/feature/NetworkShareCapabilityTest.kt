package com.jetsetslow.omniterm.shared.feature

import com.jetsetslow.omniterm.shared.core.PlatformFamily
import com.jetsetslow.omniterm.shared.platform.CapabilityResult
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertIs
import kotlin.test.assertTrue

class NetworkShareCapabilityTest {
    @Test
    fun androidKeepsAllThreeProtocols() {
        ShareProtocol.entries.forEach { protocol ->
            assertTrue(
                NetworkShareCapability.isAvailable(protocol, PlatformFamily.Android),
                "$protocol must not regress on Android",
            )
        }
        assertEquals(3, NetworkShareCapability.selectableProtocols(PlatformFamily.Android).size)
    }

    @Test
    fun iosShipsWebDavAndDeclaresTheRestUnavailable() {
        assertTrue(NetworkShareCapability.isAvailable(ShareProtocol.WebDav, PlatformFamily.Ios))
        assertFalse(NetworkShareCapability.isAvailable(ShareProtocol.Smb, PlatformFamily.Ios))
        assertFalse(NetworkShareCapability.isAvailable(ShareProtocol.Ftp, PlatformFamily.Ios))
        assertEquals(
            listOf(ShareProtocol.WebDav),
            NetworkShareCapability.selectableProtocols(PlatformFamily.Ios),
        )
    }

    @Test
    fun anUnavailableProtocolExplainsItselfRatherThanVanishing() {
        val availability = NetworkShareCapability.availability(ShareProtocol.Smb, PlatformFamily.Ios)
        val unavailable = assertIs<ShareAvailability.Unavailable>(availability)
        assertTrue(unavailable.reason.isNotBlank())
        // The user's configured share must be described, not hidden or deleted.
        assertTrue(unavailable.reason.contains("kept"), "reason must say the saved share survives")
    }

    @Test
    fun guardRefusesToRunAnUnsupportedOperation() {
        var ran = false
        val result = NetworkShareCapability.guard(ShareProtocol.Smb, PlatformFamily.Ios) {
            ran = true
            CapabilityResult.Available("listed")
        }
        assertIs<CapabilityResult.Unsupported>(result)
        assertFalse(ran, "an unsupported protocol must never reach its implementation")
    }

    @Test
    fun guardRunsASupportedOperation() {
        val result = NetworkShareCapability.guard(ShareProtocol.WebDav, PlatformFamily.Ios) {
            CapabilityResult.Available("listed")
        }
        assertEquals("listed", assertIs<CapabilityResult.Available<String>>(result).value)
    }

    @Test
    fun anUnknownPlatformIsNeverAssumedCapable() {
        ShareProtocol.entries.forEach { protocol ->
            assertFalse(NetworkShareCapability.isAvailable(protocol, PlatformFamily.Unknown))
        }
    }
}
