package com.jetsetslow.omniterm.shared.core

import kotlin.test.Test
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class RedactionTest {
    @Test
    fun removesSecretsHostsCommandsAndPaths() {
        val input = "password=hunter2 host=server.example.com ip=192.168.1.8 command=cat /home/me/key " +
            "-----BEGIN PRIVATE KEY----- secret -----END PRIVATE KEY-----"
        val result = redactDiagnostic(input, RedactionPolicy(privacyMode = true))
        assertFalse(result.contains("hunter2"))
        assertFalse(result.contains("server.example.com"))
        assertFalse(result.contains("192.168.1.8"))
        assertFalse(result.contains("cat"))
        assertFalse(result.contains("/home/me/key"))
        assertFalse(result.contains(" secret "))
        assertTrue(result.contains("<redacted>"))
    }
}
