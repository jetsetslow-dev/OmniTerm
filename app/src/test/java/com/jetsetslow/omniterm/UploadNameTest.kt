package com.jetsetslow.omniterm

import com.jetsetslow.omniterm.data.UploadName
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** A device file's name on the host stays one name in the chosen folder, whatever the app reported. */
class UploadNameTest {
    @Test fun aPlainNameIsKept() {
        assertEquals("photo 1.jpg", UploadName.from("photo 1.jpg"))
        assertEquals(".bashrc", UploadName.from(".bashrc"))
        assertEquals("zoë.txt", UploadName.from("zoë.txt"))
    }

    @Test fun onlyTheLastPartOfAPathIsKept() {
        assertEquals("c.txt", UploadName.from("a/b/c.txt"))
        assertEquals("x.txt", UploadName.from("..\\..\\x.txt"))
        assertEquals("passwd", UploadName.from("../../etc/passwd"))
    }

    @Test fun namesThatAreNotAFileAreRefused() {
        listOf(null, "", "   ", ".", "..", "a/..", "dir/", "x\\..", "\u0000").forEach { assertNull(it.toString(), UploadName.from(it)) }
        assertEquals("ab", UploadName.from("a\u0000\nb"))
    }
}
