package com.jetsetslow.omniterm.shared.data

import com.jetsetslow.omniterm.shared.platform.CapabilityResult
import com.jetsetslow.omniterm.shared.platform.SecretRef

/**
 * A saved host as the shared layer sees it. Field names mirror Android's `servers` table so one
 * backup schema can describe both implementations (ADR 0003), but a credential is a [SecretRef]:
 * the record states *that* a credential exists, never its value. Secrets live in the Keychain or
 * Keystore, never in this file.
 */
data class StoredHost(
    val id: Int = 0,
    val name: String,
    val host: String,
    val port: Int = 22,
    val username: String,
    val groupName: String? = "Default",
    val serverColor: String = "Default",
    val authType: String = "password",
    val credential: SecretRef? = null,
    val notes: String = "",
    val keepAlive: Int = 30,
    val persistentSession: Boolean = false,
    val healthScore: Int = 100,
    val lastLatency: Int = 0,
    val status: String = "offline",
)

/** Repository contract both platforms satisfy; no Room type, cursor, or SQL may appear here. */
interface HostRepository {
    suspend fun all(): List<StoredHost>
    suspend fun byId(id: Int): StoredHost?
    suspend fun upsert(host: StoredHost): Int
    suspend fun delete(id: Int)
}

/**
 * Durable text storage for one record file. The platform supplies atomicity and the protection
 * class; the shared code supplies the format.
 */
interface RecordStorage {
    suspend fun read(): String?

    /** Must replace atomically: a torn write would cost the user their whole host list. */
    suspend fun write(contents: String): CapabilityResult<Unit>
}

/**
 * Versioned line format for the iOS host file (IOS-042).
 *
 * ADR 0003 keeps Room on Android, so iOS owns its persistence. A line-per-record text file rather
 * than SQLite: Kotlin/Native 2.4.0 ships no `sqlite3` platform library, and cinterop against the
 * system SQLite needs Apple SDK headers, so a SQL store cannot be built or verified outside macOS
 * today. The dataset is a host list — tens of rows — so the format costs nothing and can be
 * replaced by SQLite behind [HostRepository] without touching a caller.
 *
 * Every field is escaped, so a host name containing a delimiter or newline cannot forge a record.
 */
object HostRecordCodec {
    const val VERSION = 1
    private const val FIELD = '\u001F'
    private const val RECORD = '\n'

    fun encode(hosts: List<StoredHost>): String = buildString {
        append(VERSION)
        hosts.forEach { host ->
            append(RECORD)
            append(
                listOf(
                    host.id.toString(),
                    host.name.escape(),
                    host.host.escape(),
                    host.port.toString(),
                    host.username.escape(),
                    (host.groupName ?: "").escape(),
                    host.serverColor.escape(),
                    host.authType.escape(),
                    (host.credential?.id ?: "").escape(),
                    host.notes.escape(),
                    host.keepAlive.toString(),
                    if (host.persistentSession) "1" else "0",
                    host.healthScore.toString(),
                    host.lastLatency.toString(),
                    host.status.escape(),
                ).joinToString(FIELD.toString()),
            )
        }
    }

    /**
     * Returns null for anything that does not parse. A caller must treat that as "could not read the
     * host list", never as "the user has no hosts" — the second would invite overwriting real data
     * with an empty file.
     */
    fun decode(raw: String?): List<StoredHost>? {
        if (raw.isNullOrEmpty()) return null
        val lines = raw.split(RECORD)
        val version = lines.first().trim().toIntOrNull() ?: return null
        if (version > VERSION) return null
        return lines.drop(1).filter { it.isNotEmpty() }.map { line ->
            val fields = line.split(FIELD)
            if (fields.size != FIELD_COUNT) return null
            StoredHost(
                id = fields[0].toIntOrNull() ?: return null,
                name = fields[1].unescape(),
                host = fields[2].unescape(),
                port = fields[3].toIntOrNull() ?: return null,
                username = fields[4].unescape(),
                groupName = fields[5].unescape().takeIf { it.isNotEmpty() },
                serverColor = fields[6].unescape(),
                authType = fields[7].unescape(),
                credential = fields[8].unescape().takeIf { it.isNotEmpty() }?.let(::SecretRef),
                notes = fields[9].unescape(),
                keepAlive = fields[10].toIntOrNull() ?: return null,
                persistentSession = fields[11] == "1",
                healthScore = fields[12].toIntOrNull() ?: return null,
                lastLatency = fields[13].toIntOrNull() ?: return null,
                status = fields[14].unescape(),
            )
        }
    }

    private const val FIELD_COUNT = 15

    private fun String.escape(): String = replace("\\", "\\\\")
        .replace(FIELD.toString(), "\\u001F")
        .replace("\n", "\\n")
        .replace("\r", "\\r")

    private fun String.unescape(): String {
        val out = StringBuilder(length)
        var index = 0
        while (index < length) {
            val char = this[index]
            if (char != '\\') {
                out.append(char)
                index++
                continue
            }
            when {
                startsWith("\\\\", index) -> { out.append('\\'); index += 2 }
                startsWith("\\u001F", index) -> { out.append(FIELD); index += 6 }
                startsWith("\\n", index) -> { out.append('\n'); index += 2 }
                startsWith("\\r", index) -> { out.append('\r'); index += 2 }
                else -> { out.append(char); index++ }
            }
        }
        return out.toString()
    }
}

/**
 * The iOS host repository. Reads are served from an in-memory copy loaded once, and every mutation
 * rewrites the file atomically through [RecordStorage].
 *
 * A failed write is reported, never swallowed: the caller must be able to tell the user their host
 * was not saved rather than show it in a list that disappears on next launch.
 */
class FileBackedHostRepository(
    private val storage: RecordStorage,
) : HostRepository {
    private var cache: MutableList<StoredHost>? = null
    private var nextId = 1

    /** @return false when a record file exists but could not be parsed; the caller must not write. */
    suspend fun load(): Boolean {
        val raw = storage.read()
        if (raw == null) {
            cache = mutableListOf()
            nextId = 1
            return true
        }
        val decoded = HostRecordCodec.decode(raw) ?: return false
        cache = decoded.toMutableList()
        nextId = (decoded.maxOfOrNull { it.id } ?: 0) + 1
        return true
    }

    override suspend fun all(): List<StoredHost> = requireLoaded().toList()

    override suspend fun byId(id: Int): StoredHost? = requireLoaded().firstOrNull { it.id == id }

    override suspend fun upsert(host: StoredHost): Int {
        val hosts = requireLoaded()
        val assigned = if (host.id == 0) host.copy(id = nextId++) else host
        val index = hosts.indexOfFirst { it.id == assigned.id }
        if (index >= 0) hosts[index] = assigned else hosts += assigned
        persist(hosts)
        return assigned.id
    }

    override suspend fun delete(id: Int) {
        val hosts = requireLoaded()
        if (hosts.removeAll { it.id == id }) persist(hosts)
    }

    private suspend fun persist(hosts: List<StoredHost>) {
        val result = storage.write(HostRecordCodec.encode(hosts))
        if (result !is CapabilityResult.Available) {
            // Roll the in-memory copy back so the UI cannot show a host the file does not have.
            load()
            error("Could not save the host list")
        }
    }

    private fun requireLoaded(): MutableList<StoredHost> =
        cache ?: error("load() must succeed before the repository is used")
}
