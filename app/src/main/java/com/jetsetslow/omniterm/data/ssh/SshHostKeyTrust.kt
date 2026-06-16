package com.jetsetslow.omniterm.data.ssh

import android.content.Context
import android.content.SharedPreferences
import android.util.Base64
import com.jcraft.jsch.HostKey
import com.jcraft.jsch.HostKeyRepository
import com.jcraft.jsch.UserInfo
import com.jetsetslow.omniterm.data.KnownHost
import com.jetsetslow.omniterm.data.SecretStore
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.runBlocking

data class HostKeyApprovalRequest(
    val host: String,
    val keyType: String,
    val fingerprint: String,
    val deferred: CompletableDeferred<Boolean>,
)

internal object SshHostKeyTrust {
    private const val PREFS = "ssh_host_key_trust"

    @Volatile private var prefs: SharedPreferences? = null

    /**
     * Set by AppViewModel to intercept first-connect host key approvals. When null (e.g. in a
     * background worker), unknown host keys are REJECTED — first-connect trust requires a user.
     */
    @Volatile var approvalHandler: ((HostKeyApprovalRequest) -> Unit)? = null

    fun init(context: Context) {
        prefs = context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
    }

    fun repository(): HostKeyRepository = TofuHostKeyRepository(
        prefs ?: error("SshHostKeyTrust.init must be called before opening SSH sessions"),
    )

    fun listKnownHosts(): List<KnownHost> {
        val p = prefs ?: return emptyList()
        return p.all.mapNotNull { (storageKey, rawValue) ->
            val decoded = readStoredStatic(rawValue as? String) ?: return@mapNotNull null
            val parts = storageKey.split("|", limit = 2)
            val host = parts.getOrNull(0)?.takeIf { it.isNotBlank() } ?: return@mapNotNull null
            val keyType = parts.getOrNull(1) ?: ""
            val fp = runCatching {
                val bytes = android.util.Base64.decode(decoded, android.util.Base64.NO_WRAP)
                val md = java.security.MessageDigest.getInstance("SHA-256")
                android.util.Base64.encodeToString(md.digest(bytes), android.util.Base64.NO_WRAP)
                    .trimEnd('=').let { "SHA256:$it" }
            }.getOrDefault("(unknown)")
            KnownHost(host, keyType, fp)
        }
    }

    private fun readStoredStatic(raw: String?): String? {
        if (raw.isNullOrBlank()) return null
        return if (SecretStore.isEncrypted(raw)) SecretStore.decrypt(raw) else raw
    }

    /** All pinned host keys as storage key ("host|type") → base64 public key, decrypted —
     *  used by the app backup so a restored fleet keeps its trust store. */
    fun exportEntries(): Map<String, String> {
        val p = prefs ?: return emptyMap()
        return p.all.entries.mapNotNull { (key, value) ->
            readStoredStatic(value as? String)?.let { key to it }
        }.toMap()
    }

    /** Import pinned host keys from a backup (encrypting at rest). Existing pins always win —
     *  a backup must never silently replace a key this device has already verified. */
    fun importEntries(entries: Map<String, String>) {
        val p = prefs ?: return
        val edit = p.edit()
        var changed = false
        for ((key, encoded) in entries) {
            if (!key.contains('|') || encoded.isBlank() || p.contains(key)) continue
            edit.putString(key, SecretStore.encrypt(encoded) ?: encoded)
            changed = true
        }
        if (changed) edit.apply()
    }

    /**
     * Every storage-key alias prefix a given host/port can be pinned under. Matches the aliasing
     * used by [hasPinnedKey] and [removeHost] so callers don't re-derive the convention.
     */
    private fun storageAliases(host: String, port: Int): Set<String> =
        setOf(host, "$host:$port", "[$host]:$port")

    /**
     * Filter a backup's exported trust entries ("<alias>|<type>" → key) down to those whose host
     * belongs to one of [hosts] (host to port). Used at restore time so pinned keys are imported
     * only for servers actually restored — orphaned trust entries for skipped/limited hosts are
     * dropped. Returns the kept entries; the count of dropped entries is `entries.size - result.size`.
     */
    fun filterEntriesForHosts(entries: Map<String, String>, hosts: Collection<Pair<String, Int>>): Map<String, String> {
        if (entries.isEmpty()) return entries
        val aliases = hosts.flatMap { (host, port) -> storageAliases(host, port) }.toSet()
        return entries.filter { (key, _) ->
            aliases.any { alias -> key.startsWith("$alias|") }
        }
    }

    /** True when at least one host key (any type) is already pinned for this host. */
    fun hasPinnedKey(host: String, port: Int): Boolean {
        val trustedPrefs = prefs ?: return false
        val aliases = storageAliases(host, port)
        return trustedPrefs.all.keys.any { key -> aliases.any { alias -> key.startsWith("$alias|") } }
    }

    fun removeHost(host: String, port: Int) {
        val trustedPrefs = prefs ?: return
        val edit = trustedPrefs.edit()
        val aliases = storageAliases(host, port)
        trustedPrefs.all.keys
            .filter { key -> aliases.any { alias -> key.startsWith("$alias|") } }
            .forEach(edit::remove)
        edit.apply()
    }

    private class TofuHostKeyRepository(
        private val prefs: SharedPreferences,
    ) : HostKeyRepository {
        override fun check(host: String?, key: ByteArray?): Int {
            val normalizedHost = host?.takeIf { it.isNotBlank() } ?: return HostKeyRepository.NOT_INCLUDED
            val publicKey = key ?: return HostKeyRepository.NOT_INCLUDED
            val hostKey = runCatching { HostKey(normalizedHost, publicKey) }.getOrNull()
                ?: return HostKeyRepository.NOT_INCLUDED
            val storageKey = storageKey(normalizedHost, hostKey.getType())
            val encoded = encode(publicKey)
            val rawStored = prefs.getString(storageKey, null)
            val trusted = readStored(rawStored)
            return when {
                trusted == null -> {
                    val handler = approvalHandler
                    val approved = if (handler != null) {
                        val fp = runCatching {
                            val bytes = Base64.decode(encoded, Base64.NO_WRAP)
                            val md = java.security.MessageDigest.getInstance("SHA-256")
                            Base64.encodeToString(md.digest(bytes), Base64.NO_WRAP)
                                .trimEnd('=').let { "SHA256:$it" }
                        }.getOrDefault("(unknown)")
                        val deferred = CompletableDeferred<Boolean>()
                        handler(HostKeyApprovalRequest(normalizedHost, hostKey.getType(), fp, deferred))
                        runBlocking { deferred.await() }
                    } else {
                        // No approval UI available (background worker / early init): fail closed.
                        // An unknown host must be trusted interactively before unattended use.
                        false
                    }
                    if (!approved) return HostKeyRepository.NOT_INCLUDED
                    val toStore = SecretStore.encrypt(encoded) ?: encoded
                    if (prefs.edit().putString(storageKey, toStore).commit()) {
                        HostKeyRepository.OK
                    } else {
                        HostKeyRepository.NOT_INCLUDED
                    }
                }
                trusted == encoded -> {
                    // Key matches — migrate legacy plaintext entry to encrypted in-place
                    if (!SecretStore.isEncrypted(rawStored)) {
                        val toStore = SecretStore.encrypt(encoded) ?: encoded
                        prefs.edit().putString(storageKey, toStore).apply()
                    }
                    HostKeyRepository.OK
                }
                else -> HostKeyRepository.CHANGED
            }
        }

        override fun add(hostkey: HostKey?, ui: UserInfo?) {
            if (hostkey == null) return
            val encoded = hostkey.getKey()
            val toStore = SecretStore.encrypt(encoded) ?: encoded
            prefs.edit()
                .putString(storageKey(hostkey.getHost(), hostkey.getType()), toStore)
                .apply()
        }

        override fun remove(host: String?, type: String?) {
            if (host.isNullOrBlank()) return
            val edit = prefs.edit()
            matchingEntries(host, type).forEach { edit.remove(it.first) }
            edit.apply()
        }

        override fun remove(host: String?, type: String?, key: ByteArray?) {
            if (host.isNullOrBlank()) return
            val encodedKey = key?.let(::encode)
            val edit = prefs.edit()
            matchingEntries(host, type)
                .filter { encodedKey == null || it.second == encodedKey }
                .forEach { edit.remove(it.first) }
            edit.apply()
        }

        override fun getKnownHostsRepositoryID(): String = PREFS

        override fun getHostKey(): Array<HostKey> =
            prefs.all.mapNotNull { (key, value) -> toHostKey(key, readStored(value as? String)) }.toTypedArray()

        override fun getHostKey(host: String?, type: String?): Array<HostKey> =
            matchingEntries(host, type).mapNotNull { toHostKey(it.first, it.second) }.toTypedArray()

        private fun matchingEntries(host: String?, type: String?): List<Pair<String, String>> {
            val prefix = host?.takeIf { it.isNotBlank() }?.let { "${it}|" }
            return prefs.all.mapNotNull { (key, value) ->
                val decoded = readStored(value as? String) ?: return@mapNotNull null
                val parts = key.split("|", limit = 2)
                val entryHost = parts.getOrNull(0)
                val entryType = parts.getOrNull(1)
                val hostMatches = prefix == null || key.startsWith(prefix)
                val typeMatches = type.isNullOrBlank() || entryType == type
                if (entryHost != null && hostMatches && typeMatches) key to decoded else null
            }
        }

        private fun toHostKey(storageKey: String, encodedKey: String?): HostKey? {
            if (encodedKey.isNullOrBlank()) return null
            val parts = storageKey.split("|", limit = 2)
            val host = parts.getOrNull(0)?.takeIf { it.isNotBlank() } ?: return null
            return runCatching { HostKey(host, Base64.decode(encodedKey, Base64.NO_WRAP)) }.getOrNull()
        }

        // Reads a stored value: decrypt if encrypted, return as-is if legacy plaintext, null if blank.
        private fun readStored(raw: String?): String? {
            if (raw.isNullOrBlank()) return null
            return if (SecretStore.isEncrypted(raw)) SecretStore.decrypt(raw) else raw
        }

        private fun storageKey(host: String, type: String): String = "$host|$type"
        private fun encode(key: ByteArray): String = Base64.encodeToString(key, Base64.NO_WRAP)
    }
}
