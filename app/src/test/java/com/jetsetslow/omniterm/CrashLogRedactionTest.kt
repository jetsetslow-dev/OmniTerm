package com.jetsetslow.omniterm

import com.jetsetslow.omniterm.data.CrashLog
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class CrashLogRedactionTest {
    @Test
    fun credentialsHostsKeysAndPrivatePathsAreRemovedWithoutLosingFrames() {
        // Assemble the sentinel at runtime so source-control scanners do not mistake the
        // deliberately fake redaction fixture for committed key material.
        val privateKeyLabel = listOf("OPENSSH", "PRIVATE", "KEY").joinToString(" ")
        val beginPrivateKey = "-----BEGIN $privateKeyLabel-----"
        val endPrivateKey = "-----END $privateKeyLabel-----"
        val report = """
            java.lang.IllegalStateException: password=hunter2 token:abc123 host 192.0.2.123
            Authorization: Bearer bearer-secret
            ssh://alice:p@ss@example.invalid/home/alice/project
            /data/user/0/com.example.app/files/private
            $beginPrivateKey
            secret-key-material
            $endPrivateKey
                at com.example.Safe.frame(Safe.kt:42)
        """.trimIndent()

        val safe = CrashLog.redactSensitive(report)

        listOf("hunter2", "abc123", "192.0.2.123", "bearer-secret", "alice:p@ss", "secret-key-material", "com.example.app")
            .forEach { secret -> assertFalse("leaked $secret in $safe", safe.contains(secret)) }
        assertTrue(safe.contains("java.lang.IllegalStateException"))
        assertTrue(safe.contains("at com.example.Safe.frame(Safe.kt:42)"))
        assertTrue(safe.contains("<redacted>"))
    }

    @Test
    fun shareBoundaryRedactsEvenIfCallerPassesRawReport() {
        val shared = CrashLog.sharePayload(
            "password=share-boundary-secret host=192.0.2.55 at com.example.Frame.run(Frame.kt:7)",
        )

        assertFalse(shared.contains("share-boundary-secret"))
        assertFalse(shared.contains("192.0.2.55"))
        assertTrue(shared.contains("OmniTerm crash report"))
        assertTrue(shared.contains("at com.example.Frame.run(Frame.kt:7)"))
    }
}
