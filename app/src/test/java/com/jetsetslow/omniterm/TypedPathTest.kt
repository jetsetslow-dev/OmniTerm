package com.jetsetslow.omniterm

import com.jetsetslow.omniterm.data.RemoteCommands
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * The SFTP address box's destination rule.
 *
 * Both call sites — the keyboard's Go action and the check button — used to inline the same three
 * lines: trim, skip if empty, `loadSftp(target)`. Two consequences of that: the rule could drift
 * between them, and a **relative** entry went to the server unresolved, listing whatever the SFTP
 * session's working directory happened to be rather than the folder the user was looking at.
 *
 * Found while porting the address box to Flutter, which had no way to type a path at all.
 */
class TypedPathTest {

    @Test
    fun `an absolute path goes where it says`() {
        assertEquals("/var/log", RemoteCommands.resolveTypedPath("/srv/www", "/var/log"))
    }

    @Test
    fun `duplicate and trailing separators are collapsed`() {
        // One directory must have one spelling, or "already here" checks and the breadcrumb
        // highlight both stop matching.
        assertEquals("/var/log", RemoteCommands.resolveTypedPath("/srv", "/var//log/"))
    }

    @Test
    fun `surrounding space is not part of the path`() {
        assertEquals("/var/log", RemoteCommands.resolveTypedPath("/srv", "  /var/log  "))
    }

    @Test
    fun `a relative entry resolves against the current directory`() {
        // The box is prefilled with where you are, so `docs` means what it would in a shell.
        assertEquals("/srv/www/docs", RemoteCommands.resolveTypedPath("/srv/www", "docs"))
        assertEquals("/srv/www/docs/img", RemoteCommands.resolveTypedPath("/srv/www", "docs/img"))
    }

    @Test
    fun `a relative entry with no current directory falls back to the root`() {
        // Before the first listing lands there is nothing to resolve against.
        assertEquals("/etc", RemoteCommands.resolveTypedPath("", "etc"))
    }

    @Test
    fun `an emptied box is a change of mind, not a jump to the root`() {
        // Going to `/` from deep in a tree is a surprising way to lose your place.
        assertNull(RemoteCommands.resolveTypedPath("/srv/www", ""))
        assertNull(RemoteCommands.resolveTypedPath("/srv/www", "   "))
    }

    @Test
    fun `the root itself is still reachable by typing it`() {
        assertEquals("/", RemoteCommands.resolveTypedPath("/srv/www", "/"))
    }
}
