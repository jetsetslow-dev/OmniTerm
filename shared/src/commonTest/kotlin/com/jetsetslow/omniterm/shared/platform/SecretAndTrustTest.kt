package com.jetsetslow.omniterm.shared.platform

import com.jetsetslow.omniterm.shared.core.DiagnosticEvent
import com.jetsetslow.omniterm.shared.core.DiagnosticLogger
import com.jetsetslow.omniterm.shared.core.IdGenerator
import kotlinx.coroutines.test.runTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertIs
import kotlin.test.assertTrue

private val VALID = HostKey("ssh-ed25519", "SHA256:" + "C".repeat(43))

private class MemorySecrets : SecretStorage {
    val items = mutableMapOf<String, ByteArray>()
    var reads = 0
    override suspend fun store(key: String, value: ByteArray): CapabilityResult<Unit> {
        items[key] = value
        return CapabilityResult.Available(Unit)
    }

    override suspend fun read(key: String): CapabilityResult<ByteArray?> {
        reads++
        return CapabilityResult.Available(items[key])
    }

    override suspend fun remove(key: String): CapabilityResult<Unit> {
        items.remove(key)
        return CapabilityResult.Available(Unit)
    }
}

private class FixedIds(private val value: String = "secret-1") : IdGenerator {
    override fun nextId(): String = value
}

private class ScriptedAuthenticator(private val outcome: CapabilityResult<Unit>) : BiometricAuthenticator {
    var calls = 0
    var cancelled = false
    override suspend fun authenticate(reason: AuthenticationReason): CapabilityResult<Unit> {
        calls++
        return outcome
    }

    override fun cancel() {
        cancelled = true
    }
}

private class RecordingLogger : DiagnosticLogger {
    val events = mutableListOf<DiagnosticEvent>()
    override fun log(event: DiagnosticEvent) {
        events += event
    }
}

class SecretVaultTest {
    @Test
    fun storedSecretsAreNamespacedAndNeverLogged() = runTest {
        val storage = MemorySecrets()
        val logger = RecordingLogger()
        val vault = SecretVault(storage, FixedIds(), logger)

        val ref = assertIs<CapabilityResult.Available<SecretRef>>(vault.store("hunter2".encodeToByteArray())).value

        assertEquals(setOf("com.jetsetslow.omniterm.secret.secret-1"), storage.items.keys)
        val logged = logger.events.flatMap { listOf(it.name) + it.fields.values }
        assertTrue(logged.none { it.contains("hunter2") || it.contains("secret-1") }, "logged: $logged")
        assertEquals("SecretRef(#)", ref.toString())
    }

    @Test
    fun missingItemIsNotFoundRatherThanAnEmptySuccess() = runTest {
        val vault = SecretVault(MemorySecrets(), FixedIds())
        val result = vault.reveal(SecretRef("absent"))
        assertEquals(CapabilityResult.Failed(PlatformError.NotFound), result)
    }

    @Test
    fun failedAuthenticationNeverReachesStorage() = runTest {
        val storage = MemorySecrets()
        val auth = ScriptedAuthenticator(CapabilityResult.Failed(PlatformError.Cancelled))
        val vault = SecretVault(storage, FixedIds(), authenticator = auth)
        val ref = assertIs<CapabilityResult.Available<SecretRef>>(vault.store("k".encodeToByteArray())).value

        val result = vault.reveal(ref, requireAuthentication = true)

        assertEquals(CapabilityResult.Failed(PlatformError.Cancelled), result)
        assertEquals(1, auth.calls)
        assertEquals(0, storage.reads, "a cancelled prompt must not fall through to a read")
    }

    @Test
    fun rotationKeepsTheReferenceAndReplacesTheValue() = runTest {
        val storage = MemorySecrets()
        val vault = SecretVault(storage, FixedIds())
        val ref = assertIs<CapabilityResult.Available<SecretRef>>(vault.store("old".encodeToByteArray())).value

        val rotated = assertIs<CapabilityResult.Available<SecretRef>>(vault.store("new".encodeToByteArray(), existing = ref)).value

        assertEquals(ref, rotated)
        assertEquals(1, storage.items.size)
        val stored = assertIs<CapabilityResult.Available<ByteArray>>(vault.reveal(ref)).value
        assertEquals("new", stored.decodeToString())
    }

    @Test
    fun orphanedSecretsAreRemoved() = runTest {
        val storage = MemorySecrets()
        val vault = SecretVault(storage, FixedIds())
        val kept = SecretRef("kept")
        val orphan = SecretRef("orphan")
        vault.store("a".encodeToByteArray(), existing = kept)
        vault.store("b".encodeToByteArray(), existing = orphan)

        assertEquals(1, vault.removeOrphans(referenced = setOf(kept), known = setOf(kept, orphan)))
        assertEquals(setOf("com.jetsetslow.omniterm.secret.kept"), storage.items.keys)
    }

    @Test
    fun wipeClearsKeyMaterial() {
        val bytes = "private".encodeToByteArray()
        bytes.wipe()
        assertTrue(bytes.all { it == 0.toByte() })
    }
}

class HostKeyTrustTest {
    @Test
    fun unknownHostIsNeverAutoTrusted() = runTest {
        val trust = HostKeyTrust(MemoryHosts())
        assertEquals(HostKeyDecision.Unknown, trust.evaluate(SshEndpoint("a.example", 22, "root"), VALID))
    }

    @Test
    fun changedKeyReportsThePreviousKey() = runTest {
        val store = MemoryHosts()
        val endpoint = SshEndpoint("a.example", 22, "root")
        val trust = HostKeyTrust(store)
        trust.trust(endpoint, VALID)

        val other = HostKey("ssh-rsa", "SHA256:" + "D".repeat(43))
        val decision = trust.evaluate(endpoint, other)

        assertEquals(HostKeyDecision.Changed(VALID), decision)
        assertEquals(VALID, store.entries[hostKeyAlias(endpoint)], "evaluation must not overwrite trust")
    }

    @Test
    fun aliasSeparatesPortsAndIgnoresHostnameCase() = runTest {
        val store = MemoryHosts()
        val trust = HostKeyTrust(store)
        trust.trust(SshEndpoint("Host.Example", 22, "root"), VALID)

        assertEquals(HostKeyDecision.Trusted, trust.evaluate(SshEndpoint("host.example", 22, "root"), VALID))
        assertEquals(HostKeyDecision.Unknown, trust.evaluate(SshEndpoint("host.example", 2222, "root"), VALID))
    }

    @Test
    fun malformedKeyMaterialIsRejectedAndNeverStored() = runTest {
        val store = MemoryHosts()
        val trust = HostKeyTrust(store)
        val endpoint = SshEndpoint("a.example", 22, "root")

        listOf(
            HostKey("", "SHA256:" + "A".repeat(43)),
            HostKey("ssh-ed25519", ""),
            HostKey("ssh-ed25519", "MD5:aa:bb:cc"),
            HostKey("ssh-ed25519", "SHA256:tooshort"),
            HostKey("ssh-ed25519", "SHA256:" + "A".repeat(42) + " "),
            HostKey("ssh-ed25519", "unprefixed" + "A".repeat(33)),
        ).forEach { key ->
            assertIs<HostKeyDecision.Malformed>(trust.evaluate(endpoint, key), "expected rejection for $key")
            assertIs<CapabilityResult.Failed>(trust.trust(endpoint, key))
        }
        assertTrue(store.entries.isEmpty())
    }

    @Test
    fun forgettingAHostClearsOnlyThatAlias() = runTest {
        val store = MemoryHosts()
        val trust = HostKeyTrust(store)
        trust.trust(SshEndpoint("a.example", 22, "root"), VALID)
        trust.trust(SshEndpoint("b.example", 22, "root"), VALID)

        trust.forget(SshEndpoint("a.example", 22, "root"))

        assertFalse(store.entries.containsKey("a.example:22"))
        assertTrue(store.entries.containsKey("b.example:22"))
    }
}

private class MemoryHosts : KnownHostsStore {
    val entries = mutableMapOf<String, HostKey>()
    override suspend fun find(alias: String): HostKey? = entries[alias]
    override suspend fun put(alias: String, key: HostKey) {
        entries[alias] = key
    }

    override suspend fun remove(alias: String) {
        entries.remove(alias)
    }
}
