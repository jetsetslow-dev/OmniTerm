package com.jetsetslow.omniterm.shared

import kotlin.test.Test
import kotlin.test.assertEquals

class OmniTermSharedTest {
    @Test
    fun frameworkIdentityIsStable() {
        assertEquals("OmniTermShared", OmniTermShared.frameworkName)
        assertEquals(1, OmniTermShared.schemaVersion)
    }
}
