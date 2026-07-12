package com.jetsetslow.omniterm

import com.jetsetslow.omniterm.ui.gunzipBackupBounded
import com.jetsetslow.omniterm.ui.validateBackupCryptoParameters
import com.jetsetslow.omniterm.ui.validateBackupJsonNesting
import java.io.ByteArrayOutputStream
import java.util.zip.GZIPOutputStream
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertThrows
import org.junit.Test

class BackupSafetyTest {
    @Test
    fun boundedGunzipRoundTripsNormalPayload() {
        val plain = "synthetic-backup".repeat(100).toByteArray()
        assertArrayEquals(plain, gunzipBackupBounded(gzip(plain), maxPlainBytes = 64 * 1024))
    }

    @Test
    fun rejectsExcessiveJsonNestingWithoutBeingFooledByQuotedBraces() {
        validateBackupJsonNesting("{\"text\":\"[[[\",\"ok\":[1]}", maxDepth = 3)
        assertThrows(IllegalArgumentException::class.java) {
            validateBackupJsonNesting("[[[[0]]]]", maxDepth = 3)
        }
        assertThrows(IllegalArgumentException::class.java) {
            validateBackupJsonNesting("{\"x\":[1}", maxDepth = 3)
        }
    }

    @Test
    fun boundedGunzipRejectsExpansionBomb() {
        val compressed = gzip(ByteArray(2 * 1024 * 1024) { 'A'.code.toByte() })
        assertThrows(IllegalArgumentException::class.java) {
            gunzipBackupBounded(compressed, maxPlainBytes = 64 * 1024)
        }
    }

    @Test
    fun cryptoEnvelopeBoundsRejectHostileParameters() {
        validateBackupCryptoParameters(600_000, 16, 12, 128)
        for (badIterations in listOf(-1, 0, 99_999, 1_000_001, Int.MAX_VALUE)) {
            assertThrows(IllegalArgumentException::class.java) {
                validateBackupCryptoParameters(badIterations, 16, 12, 128)
            }
        }
        assertThrows(IllegalArgumentException::class.java) {
            validateBackupCryptoParameters(600_000, 8, 12, 128)
        }
        assertThrows(IllegalArgumentException::class.java) {
            validateBackupCryptoParameters(600_000, 16, 16, 128)
        }
        assertThrows(IllegalArgumentException::class.java) {
            validateBackupCryptoParameters(600_000, 16, 12, 1025, maxCiphertextBytes = 1024)
        }
    }

    private fun gzip(bytes: ByteArray): ByteArray {
        val output = ByteArrayOutputStream()
        GZIPOutputStream(output).use { it.write(bytes) }
        return output.toByteArray()
    }
}
