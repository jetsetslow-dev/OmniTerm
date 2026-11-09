package com.jetsetslow.omniterm

import com.jetsetslow.omniterm.data.ServerEntity
import com.jetsetslow.omniterm.data.SshLink
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** `ssh://` links: what is read from one, what is dropped, and which links are refused. */
class SshLinkTest {

    @Test fun theAddressPortAndUserAreRead() {
        assertEquals(SshLink("nas.lan", 22, null), SshLink.parse("ssh://nas.lan"))
        assertEquals(SshLink("nas.lan", 2222, "admin"), SshLink.parse("ssh://admin@nas.lan:2222"))
        assertEquals(SshLink("Pi", 22, null), SshLink.parse("  SSH://Pi  "))
        assertEquals(SshLink("my_host", 22, null), SshLink.parse("ssh://my_host"))
        assertEquals(SshLink("2001:db8::1", 2200, "root"), SshLink.parse("ssh://root@[2001:db8::1]:2200"))
    }

    @Test fun whatFollowsTheAddressIsNotPartOfIt() {
        // electerm#4357: the trailing slash was read as part of the address.
        assertEquals(SshLink("127.0.0.1", 22, null), SshLink.parse("ssh://127.0.0.1/"))
        assertEquals(SshLink("h", 2222, "u"), SshLink.parse("ssh://u@h:2222/home/u?x=1#top"))
        assertEquals(SshLink("h", 22, null), SshLink.parse("ssh://h?x=1"))
        assertEquals(SshLink("h", 22, null), SshLink.parse("ssh://h#f"))
    }

    @Test fun aPasswordAndParametersAreDropped() {
        val withPassword = SshLink.parse("ssh://admin:s3cret@nas.lan")!!
        assertEquals(SshLink("nas.lan", 22, "admin"), withPassword)
        assertFalse(withPassword.label.contains("s3cret"))
        assertEquals("admin@nas.lan", withPassword.label)
        assertEquals(
            SshLink("nas.lan", 22, "admin"),
            SshLink.parse("ssh://admin;fingerprint=ssh-ed25519-AAAAC3NzaC1lZDI1NTE5@nas.lan"),
        )
        // An escaped @ in a password is not where the address starts.
        assertEquals(SshLink("nas.lan", 22, "admin"), SshLink.parse("ssh://admin:p%40ss@nas.lan"))
    }

    @Test fun anEscapedUserIsDecoded() {
        assertEquals("jo doe", SshLink.parse("ssh://jo%20doe@win.lan")!!.user)
        assertEquals("ana@corp", SshLink.parse("ssh://ana%40corp@win.lan")!!.user)
        assertEquals("zoë", SshLink.parse("ssh://zo%C3%AB@h")!!.user)
        assertNull("an empty user is no user", SshLink.parse("ssh://@h")!!.user)
    }

    @Test fun unusableLinksAreRefused() {
        listOf(
            "https://nas.lan",
            "ssh:nas.lan",
            "ssh://",
            "ssh://user@",
            "ssh://h:",
            "ssh://h:0",
            "ssh://h:70000",
            "ssh://h:22x",
            "ssh://ho st",
            "ssh://h;x=1",
            "ssh://-oProxyCommand=evil",
            "ssh://-l@h",
            "ssh://%0Aroot@h",
            "ssh://us%ZZer@h",
            "ssh://us%+1er@h",
            "ssh://us%4@h",
            "ssh://%C3@h",
            "ssh://[2001:db8::1",
            "ssh://${"a".repeat(257)}@h",
        ).forEach { assertNull(it, SshLink.parse(it)) }
    }

    @Test fun theLabelShowsOnlyWhatIsKept() {
        assertEquals("nas.lan", SshLink("nas.lan", 22, null).label)
        assertEquals("root@[2001:db8::1]:2200", SshLink("2001:db8::1", 2200, "root").label)
    }

    @Test fun aLinkWrittenAgainReadsBackTheSame() {
        listOf(
            SshLink("nas.lan", 22, null),
            SshLink("2001:db8::1", 2200, "root"),
            SshLink("win.lan", 22, "jo doe"),
            SshLink("win.lan", 22, "ana@corp"),
            SshLink("h", 2222, "a:b;c/d?e#f%g"),
            SshLink("h", 22, "zoë"),
        ).forEach { link -> assertEquals(link.uri, link, SshLink.parse(link.uri)) }
        assertEquals("ssh://jo%20doe@win.lan", SshLink("win.lan", 22, "jo doe").uri)
    }

    @Test fun aLinkMatchesItsSavedHost() {
        val srv = ServerEntity(name = "NAS", host = " NAS.lan ", port = 2222, username = "admin")
        assertTrue(SshLink("nas.lan", 2222, null).matches(srv, loginName = "admin"))
        assertTrue(SshLink("nas.lan", 2222, "admin").matches(srv, loginName = "admin"))
        assertFalse("another user", SshLink("nas.lan", 2222, "root").matches(srv, loginName = "admin"))
        assertFalse("another port", SshLink("nas.lan", 22, null).matches(srv, loginName = "admin"))
        assertFalse("another host", SshLink("nas2.lan", 2222, null).matches(srv, loginName = "admin"))
        val v6 = ServerEntity(name = "v6", host = "[2001:db8::1]", port = 22, username = "u")
        assertTrue(SshLink("2001:DB8::1", 22, "u").matches(v6, loginName = "u"))
    }
}
