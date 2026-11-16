package com.jetsetslow.omniterm.data.tunnel

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Test

class CloudflareAccessSettingsTest {
    private val saved = CloudflareAccessSettings("ssh.example.com", "fixture-id", "fixture-secret")

    @Test fun reopeningNeverReturnsEitherTokenField() {
        assertEquals(CloudflareAccessSettings("ssh.example.com", "", ""), saved.forEditor())
    }

    @Test fun diagnosticsNeverIncludeEitherTokenField() {
        assertFalse(saved.toString().contains(saved.clientId))
        assertFalse(saved.toString().contains(saved.clientSecret))
    }

    @Test fun emptyFieldsKeepSavedTokenAndReplacementFieldsWin() {
        assertEquals(saved, saved.forEditor().keepingToken(saved))
        assertEquals(saved.copy(clientId = "replacement"), saved.forEditor().copy(clientId = "replacement").keepingToken(saved))
        assertEquals(saved.copy(clientSecret = "replacement"), saved.forEditor().copy(clientSecret = "replacement").keepingToken(saved))
        assertEquals(saved.forEditor(), saved.forEditor().keepingToken(null))
    }
}
