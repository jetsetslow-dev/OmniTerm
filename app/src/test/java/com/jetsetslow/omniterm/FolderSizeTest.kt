package com.jetsetslow.omniterm

import com.jetsetslow.omniterm.data.RemoteCommands
import com.jetsetslow.omniterm.data.RemoteParsers
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * SFTP "Measure size" on a folder. A listing shows a folder's index size, so this is the number
 * people actually want; the same cases as Flutter's `remote_commands_folder_size_test.dart`.
 */
class FolderSizeTest {

    @Test
    fun `the path is quoted, not interpolated`() {
        // A remote path comes from a listing on someone else's machine; `; rm -rf ~` is a legal name.
        val command = RemoteCommands.folderSize("/srv/; rm -rf ~")
        assertTrue(command.contains("'/srv/; rm -rf ~'"))
        assertFalse(command.contains("du -shx -- /srv/; rm"))
        assertTrue(RemoteCommands.folderSize("/srv/it's").contains("'/srv/it'\\''s'"))
    }

    @Test
    fun `it stays on one filesystem and keeps errors`() {
        // Network mounts under `/` would otherwise be walked; the warning marks a partial total.
        assertTrue(RemoteCommands.folderSize("/").contains("du -shx"))
        assertTrue(RemoteCommands.folderSize("/srv").contains("2>&1"))
    }

    @Test
    fun `the ordinary answer and a bare byte count`() {
        assertEquals(RemoteParsers.FolderSize("120K", complete = true), RemoteParsers.parseFolderSize("120K\t/config\n"))
        assertEquals("1.2G", RemoteParsers.parseFolderSize("1.2G\t/srv/media\n")?.size)
        assertEquals("284", RemoteParsers.parseFolderSize("284\t/srv\n")?.size)
    }

    @Test
    fun `a partial total is returned and flagged`() {
        val output = "du: cannot read directory '/root': Permission denied\n4.0K\t/root\n"
        assertEquals(RemoteParsers.FolderSize("4.0K", complete = false), RemoteParsers.parseFolderSize(output))
    }

    @Test
    fun `no number at all is unmeasurable, never zero`() {
        assertNull(RemoteParsers.parseFolderSize("du: cannot access '/nope': No such file or directory\n"))
        assertNull(RemoteParsers.parseFolderSize("sh: du: not found\n"))
        assertNull(RemoteParsers.parseFolderSize(""))
        assertNull(RemoteParsers.parseFolderSize("something went wrong\n"))
    }
}
