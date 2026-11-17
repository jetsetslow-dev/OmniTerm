package com.jetsetslow.omniterm

import com.jetsetslow.omniterm.ui.FleetPush
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.File

/** Where a pushed file lands on a host, from the path typed once for every host. */
class FleetPushTest {

    @Test
    fun aFolderPathKeepsTheFileNameAndAnyOtherPathRenamesIt() {
        assertEquals("/etc/app/app.conf", push("/etc/app/").remotePath("/home/u"))
        assertEquals("/etc/app/main.conf", push("/etc/app/main.conf").remotePath("/home/u"))
    }

    @Test
    fun relativePathsAndTildeAreInTheHomeFolder() {
        assertEquals("/home/u/app.conf", push("").remotePath("/home/u"))
        assertEquals("/home/u/app.conf", push("~").remotePath("/home/u/"))
        assertEquals("/home/u/app.conf", push("~/").remotePath("/home/u"))
        assertEquals("/home/u/bin/tool", push("~/bin/tool").remotePath("/home/u"))
        assertEquals("/home/u/conf/app.conf", push(" conf/ ").remotePath("/home/u"))
        assertEquals("a root login's home", "/app.conf", push("~/").remotePath("/"))
        assertEquals("a Windows home over SFTP", "/C:/Users/u/app.conf", push("~/").remotePath("/C:/Users/u"))
    }

    @Test
    fun aDestinationIsOneLine() {
        assertTrue(FleetPush.validDestination("/etc/my app/"))
        assertFalse(FleetPush.validDestination("/tmp/x\nrm -rf /"))
        assertFalse(FleetPush.validDestination("/tmp/x\u0000"))
    }

    @Test
    fun aFileOverTheLimitIsRefusedAndOneAtItIsCopiedWhole() {
        val bytes = ByteArray(1000) { it.toByte() }
        val out = ByteArrayOutputStream()
        assertEquals(1000L, FleetPush.copyAtMost(ByteArrayInputStream(bytes), out, max = 1000))
        assertArrayEquals(bytes, out.toByteArray())
        assertEquals(-1L, FleetPush.copyAtMost(ByteArrayInputStream(bytes), ByteArrayOutputStream(), max = 999))
    }

    private fun push(destination: String) = FleetPush("app.conf", 10, File("unused"), destination)
}
