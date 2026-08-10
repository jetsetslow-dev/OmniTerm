package com.jetsetslow.omniterm

import com.jetsetslow.omniterm.data.RemoteCommands
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The recursive SFTP search's refusal check.
 *
 * `runSftpSearch` used `sftpReadError`, which inspects the first non-blank line. For a search that
 * is the **first hit**, so a file legitimately named `no such file.txt` reported itself as a
 * permission error and blanked the whole result set it appeared in.
 *
 * Found while porting the search to Flutter, where the same check was about to be written.
 */
class SearchSudoFailureTest {

    @Test
    fun `a refusal is returned as the complaint to show`() {
        assertEquals(
            "sudo: 3 incorrect password attempts",
            RemoteCommands.searchSudoFailure("sudo: 3 incorrect password attempts\n"),
        )
    }

    @Test
    fun `a search that simply ran is not a failure`() {
        assertNull(RemoteCommands.searchSudoFailure("f\t/etc/passwd\n"))
        assertNull(RemoteCommands.searchSudoFailure(""))
    }

    @Test
    fun `leading blank lines do not hide the complaint`() {
        // sudo's lecture and prompt suppression both leave blank lines ahead of the real message.
        assertEquals("permission denied", RemoteCommands.searchSudoFailure("\n\n  permission denied\n"))
    }

    @Test
    fun `a tagged hit is data, however much its name reads like an error`() {
        // The regression this test exists for. The first hit is exactly where it bites.
        assertNull(RemoteCommands.searchSudoFailure("f\t/srv/no such file.txt\nf\t/srv/b.txt\n"))
        assertNull(RemoteCommands.searchSudoFailure("d\t/srv/permission denied\n"))
    }

    @Test
    fun `the case the host chose does not matter`() {
        assertEquals("Permission Denied", RemoteCommands.searchSudoFailure("Permission Denied\n"))
    }

    @Test
    fun `a read-only mount is a failure the list now recognises`() {
        // An extract or compress into a read-only mount used to match nothing and be reported as a
        // success.
        assertTrue(RemoteCommands.sudoFailureMarkers.contains("read-only file system"))
    }
}
