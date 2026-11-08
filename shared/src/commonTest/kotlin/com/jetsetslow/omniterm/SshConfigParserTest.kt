package com.jetsetslow.omniterm

import com.jetsetslow.omniterm.data.SshConfigJump
import com.jetsetslow.omniterm.data.SshConfigParser
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlin.test.Test

/** ssh_config files read as `ssh` reads them: first value wins, wildcard blocks fill in. */
class SshConfigParserTest {

    @Test
    fun hostsTakeTheFirstValueOfEachSettingAndWildcardBlocksFillIn() {
        val file = SshConfigParser.parse(
            """
            # Personal servers
            Host web web.example.com
                HostName 203.0.113.10
                User deploy
                Port 2222
                IdentityFile ~/.ssh/id_ed25519
                ForwardAgent yes

            Host nas
                HostName %h.lan
                Compression=yes

            Host *.example.com
                User nobody

            Host *
                User admin
                ServerAliveInterval 15
                Port 22
            """.trimIndent(),
        )

        assertEquals(listOf("web", "nas"), file.hosts.map { it.alias })
        val web = file.hosts[0]
        assertEquals("203.0.113.10", web.hostName)
        assertEquals("deploy", web.user, "the host's own User, not the later Host * one")
        assertEquals(2222, web.port)
        assertEquals("~/.ssh/id_ed25519", web.identityFile)
        assertTrue(web.forwardAgent)
        assertEquals(15, web.keepAliveSeconds)

        val nas = file.hosts[1]
        assertEquals("nas.lan", nas.hostName)
        assertEquals("admin", nas.user)
        assertEquals(22, nas.port)
        assertTrue(nas.compression)
        assertFalse(nas.forwardAgent)
        assertTrue(file.skipped.isEmpty())
    }

    @Test
    fun aJumpHostIsResolvedThroughItsOwnEntry() {
        val file = SshConfigParser.parse(
            """
            Host bastion
              HostName bastion.example.net
              User jump
              Port 2200
              IdentityFile ~/.ssh/bastion_key
            Host db
              HostName 10.0.0.5
              User postgres
              ProxyJump bastion
            Host app
              HostName 10.0.0.6
              User app
              ProxyJump ops@198.51.100.7:2022,bastion
            Host old
              HostName 10.0.0.7
              User old
              ProxyCommand ssh -q -W %h:%p bastion
            Host odd
              HostName 10.0.0.8
              User odd
              ProxyCommand nc -X 5 -x proxy:1080 %h %p
            """.trimIndent(),
        )
        val byAlias = file.hosts.associateBy { it.alias }

        assertEquals(SshConfigJump("bastion.example.net", 2200, "jump", "~/.ssh/bastion_key"), byAlias.getValue("db").jump)
        assertEquals(SshConfigJump("198.51.100.7", 2022, "ops", null), byAlias.getValue("app").jump)
        assertEquals(listOf("Goes through 2 jump hosts; only the first, ops@198.51.100.7:2022, is used."), byAlias.getValue("app").notes)
        assertEquals("bastion.example.net", byAlias.getValue("old").jump?.host, "ProxyCommand ssh -W is a jump host")
        assertNull(byAlias.getValue("odd").jump)
        assertEquals(listOf("Its ProxyCommand is not supported."), byAlias.getValue("odd").notes)
    }

    @Test
    fun patternsNegationMatchAndIncludeAreHandledAsSshDoes() {
        val file = SshConfigParser.parse(
            """
            Include ~/.ssh/config.d/*
            Host * !secure
              User everyone
            Host secure
              HostName 192.0.2.1
              LocalForward 8080 localhost:80
            Match host secure
              User ignored
            Host plain
              HostName "192.0.2.2"
            """.trimIndent(),
        )
        val byAlias = file.hosts.associateBy { it.alias }

        assertEquals("", byAlias.getValue("secure").user, "negated out of the Host * block")
        assertEquals(listOf("Its local port forwards are not imported."), byAlias.getValue("secure").notes)
        assertEquals("192.0.2.2", byAlias.getValue("plain").hostName)
        assertEquals("everyone", byAlias.getValue("plain").user)
        assertEquals(2, file.skipped.size)
        assertTrue(file.skipped.any { it.startsWith("Include ~/.ssh/config.d/*") })
        assertTrue(file.skipped.any { it.startsWith("Match blocks") })
    }

    @Test
    fun aFileWithOnlyWildcardsOffersNoHosts() {
        assertTrue(SshConfigParser.parse("Host *\n  User a\n").hosts.isEmpty())
        assertTrue(SshConfigParser.parse("").hosts.isEmpty())
    }
}
