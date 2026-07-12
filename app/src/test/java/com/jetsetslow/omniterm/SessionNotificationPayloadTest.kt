package com.jetsetslow.omniterm

import com.jetsetslow.omniterm.ui.decodeSessionNotificationPayload
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class SessionNotificationPayloadTest {
    @Test
    fun decode_preserves_server_names_with_pipe_characters() {
        val decoded = decodeSessionNotificationPayload("session-1\nprod|db|primary")

        assertEquals("session-1", decoded?.id)
        assertEquals("prod|db|primary", decoded?.name)
    }

    @Test
    fun decode_rejects_legacy_or_blank_payloads() {
        assertNull(decodeSessionNotificationPayload("session-1|prod"))
        assertNull(decodeSessionNotificationPayload("\nprod"))
        assertNull(decodeSessionNotificationPayload(""))
    }
}
