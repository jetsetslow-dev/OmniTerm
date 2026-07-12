package com.jetsetslow.omniterm

import com.jetsetslow.omniterm.ui.hashPinForStorage
import com.jetsetslow.omniterm.ui.storedPinLength
import com.jetsetslow.omniterm.ui.verifyStoredPin
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/**
 * PIN hashing uses android.util.Base64, so these need Robolectric. Like the other Robolectric
 * classes this one is excluded on Linux aarch64 hosts (build.gradle.kts) and runs in CI.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class PinHashRobolectricTest {

    @Test
    fun pin_hash_round_trips_and_rejects_wrong_pin() {
        val stored = hashPinForStorage("4711")
        assertTrue(stored.startsWith("pin:v2:210000:"))
        assertFalse("PIN digits must not appear in the stored value", stored.contains("4711"))
        assertTrue(verifyStoredPin(stored, "4711"))
        assertFalse(verifyStoredPin(stored, "4712"))
        assertFalse(verifyStoredPin(stored, ""))
        assertEquals(4, storedPinLength(stored))
    }

    @Test
    fun pin_hashes_are_salted() {
        assertNotEquals("same PIN must hash differently each time", hashPinForStorage("4711"), hashPinForStorage("4711"))
    }

    @Test
    fun tampered_hash_is_rejected() {
        val stored = hashPinForStorage("4711")
        assertFalse(verifyStoredPin(stored.dropLast(4) + ":99", "4711"))
        assertFalse(verifyStoredPin("pin:v1:not-base64:also-not:4", "4711"))
    }

    @Test
    fun legacy_v1_hash_still_verifies_for_migration() {
        val pin = "4711"
        val salt = ByteArray(16) { it.toByte() }
        val hash = java.security.MessageDigest.getInstance("SHA-256")
            .digest(salt + pin.toByteArray())
        val flags = android.util.Base64.NO_WRAP
        val stored = "pin:v1:${android.util.Base64.encodeToString(salt, flags)}:" +
            "${android.util.Base64.encodeToString(hash, flags)}:${pin.length}"
        assertTrue(verifyStoredPin(stored, pin))
        assertEquals(pin.length, storedPinLength(stored))
    }
}
