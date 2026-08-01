package com.jetsetslow.omniterm.shared.network

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class WebDavMultistatusParserTest {
    @Test
    fun parsesNamespaceVariantsAndEntities() {
        val xml = """
            <D:multistatus xmlns:D="DAV:">
              <D:response><D:href>/root/</D:href><D:propstat><D:prop><D:resourcetype><D:collection/></D:resourcetype></D:prop></D:propstat></D:response>
              <response xmlns="DAV:"><href>/root/a%20b.txt?ignored=false&amp;x=1</href><propstat><prop><getcontentlength>42</getcontentlength></prop></propstat></response>
            </D:multistatus>
        """.trimIndent()
        val entries = parseWebDavMultistatus(xml)
        assertEquals(2, entries.size)
        assertTrue(entries.first().directory)
        assertEquals(42, entries.last().size)
        assertTrue(entries.last().href.contains("&x=1"))
    }
}
