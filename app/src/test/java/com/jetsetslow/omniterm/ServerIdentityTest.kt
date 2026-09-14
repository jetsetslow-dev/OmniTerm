package com.jetsetslow.omniterm

import com.jetsetslow.omniterm.data.CredentialProfileEntity
import com.jetsetslow.omniterm.data.ServerEntity
import com.jetsetslow.omniterm.data.serverIdentity
import com.jetsetslow.omniterm.data.profileServerConflicts
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Test

class ServerIdentityTest {
    private val host = ServerEntity(name = "Current name", host = "HOST.example", port = 2222,
        username = "deploy", authType = "password", authPassword = "current fixture secret")

    @Test fun namesAndRotatedPasswordsDoNotChangeIdentity() {
        assertEquals(serverIdentity(host, emptyList()), serverIdentity(host.copy(
            name = "Backup name", host = " host.example ", authPassword = "old fixture secret",
        ), emptyList()))
    }

    @Test fun portUserAndAuthMethodDistinguishConnections() {
        for (other in listOf(host.copy(port = 22), host.copy(username = "Deploy"), host.copy(authType = "key"))) {
            assertNotEquals(serverIdentity(host, emptyList()), serverIdentity(other, emptyList()))
        }
    }

    @Test fun profilesUseTheirEffectiveLoginAndMissingProfilesNeverMatch() {
        val profile = CredentialProfileEntity(id = 9, profileName = "Renamed profile",
            username = "deploy", authType = "password")
        val indirect = host.copy(username = "", authType = "profile", authProfileId = 9)
        assertEquals(serverIdentity(host, emptyList()), serverIdentity(indirect, listOf(profile)))
        assertNull(serverIdentity(indirect, emptyList()))
    }

    @Test fun profileEditsReportAllNewDirectAndIndirectCollisions() {
        val edited = CredentialProfileEntity(id = 1, profileName = "Edited", username = "root", authType = "key")
        val other = edited.copy(id = 2, profileName = "Other", authType = "password")
        val servers = listOf(
            host.copy(id = 1, name = "Edited host", authType = "profile", authProfileId = 1),
            host.copy(id = 2, name = "Direct host", username = "root"),
            host.copy(id = 3, name = "Other profile host", authType = "profile", authProfileId = 2),
        )
        assertEquals(listOf("Edited host" to "Direct host", "Edited host" to "Other profile host"),
            profileServerConflicts(servers, listOf(edited, other), edited.copy(authType = "password")))
    }

    @Test fun namesPasswordsAndAlreadyDuplicatedPairsDoNotBlockProfileEdits() {
        val profile = CredentialProfileEntity(id = 1, profileName = "Old", username = "deploy", authType = "password")
        val servers = listOf(host.copy(id = 1), host.copy(id = 2, authType = "profile", authProfileId = 1))
        assertEquals(emptyList<Pair<String, String>>(), profileServerConflicts(servers, listOf(profile),
            profile.copy(profileName = "New", password = "rotated fixture secret")))
    }

    @Test fun distinctPortsUsersAndAuthMethodsRemainAllowedAfterProfileEdit() {
        val profile = CredentialProfileEntity(id = 1, profileName = "Shared", username = "other", authType = "password")
        val indirect = host.copy(id = 1, name = "Indirect", authType = "profile", authProfileId = 1)
        for (different in listOf(host.copy(port = 22), host.copy(username = "Deploy"), host.copy(authType = "key"))) {
            assertEquals(emptyList<Pair<String, String>>(), profileServerConflicts(
                listOf(indirect, different.copy(id = 2)), listOf(profile), profile.copy(username = "deploy")))
        }
    }

    @Test fun resolvingAMissingProfileCannotIntroduceADuplicateLogin() {
        val profile = CredentialProfileEntity(id = 9, profileName = "Recovered", username = "deploy", authType = "password")
        val servers = listOf(host.copy(id = 1), host.copy(id = 2, name = "Unresolved", authType = "profile", authProfileId = 9))
        assertEquals(listOf("Current name" to "Unresolved"), profileServerConflicts(servers, emptyList(), profile))
    }
}
