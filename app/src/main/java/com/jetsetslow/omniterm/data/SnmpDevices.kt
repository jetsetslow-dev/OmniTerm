package com.jetsetslow.omniterm.data

/**
 * SNMP devices (switches, routers, UPSes, printers, NAS boxes) polled from the phone over UDP,
 * with SNMP v2c or v3. Read-only: an [SnmpSession] can only GET and walk (GETBULK), so nothing on
 * a device can be changed from here.
 *
 * This file is plain Kotlin: what to read, how to read the answers, and why a device refused. The
 * SNMP library sits behind [SnmpEngine] ([Snmp4jEngine] on Android), so another engine can replace
 * it without touching the feature.
 *
 * What is read follows the standard MIBs a monitoring tool such as LibreNMS reads first: the
 * system group, the interface tables (IF-MIB, 64-bit counters where the device has them) and the
 * host resources CPU and storage tables.
 */
object SnmpDevices {
    const val DEFAULT_PORT = 161
    const val TIMEOUT_MS = 3_000L
    const val RETRIES = 1
    /** Rows read per column at most, so a device with a huge table cannot run a poll for ever. */
    const val MAX_ROWS = 512
    const val MIN_PASSWORD = 8

    val AUTH_PROTOCOLS = listOf("SHA", "SHA-256", "SHA-512", "SHA-224", "SHA-384", "MD5")
    val PRIV_PROTOCOLS = listOf("AES", "AES-256", "AES-192", "DES")

    /** How to reach and sign in to one device; secrets in clear here, encrypted at rest. */
    data class Access(
        val host: String,
        val port: Int = DEFAULT_PORT,
        val version: Int = 2,
        val community: String = "",
        val user: String = "",
        val authProtocol: String = "",
        val authPassword: String = "",
        val privProtocol: String = "",
        val privPassword: String = "",
    )

    /** Why a device is not polled while its tunnel is in use: SNMP is UDP, and it never goes direct instead. */
    const val NOT_THROUGH_TUNNEL =
        "Not polled: this device is reached only through its VPN tunnel, and SNMP uses UDP, which tunnels do not carry yet. It is never polled directly instead."
    const val NEEDS_ANDROID_8 = "SNMP needs Android 8.0 or later on this phone."
    /** The most a whole poll may take: its system read and every column. */
    const val POLL_LIMIT_MS = 60_000L
    const val TOO_SLOW = "the device took more than a minute to answer everything, so the poll was stopped"

    /** Why [access] cannot be used as entered, or null. */
    fun problem(access: Access): String? = when {
        access.host.isBlank() -> "Enter the device's address"
        access.port !in 1..65535 -> "The port must be 1 to 65535"
        access.version == 2 && access.community.isEmpty() -> "Enter the community"
        access.version == 3 && access.user.isBlank() -> "Enter the SNMPv3 user"
        access.version == 3 && access.authProtocol.isNotEmpty() && access.authPassword.length < MIN_PASSWORD ->
            "The authentication password needs at least $MIN_PASSWORD characters"
        access.version == 3 && access.privProtocol.isNotEmpty() && access.authProtocol.isEmpty() ->
            "Privacy needs authentication too"
        access.version == 3 && access.privProtocol.isNotEmpty() && access.privPassword.length < MIN_PASSWORD ->
            "The privacy password needs at least $MIN_PASSWORD characters"
        access.version !in setOf(2, 3) -> "Use SNMP v2c or v3"
        else -> null
    }

    data class Interface(
        val index: Int,
        val name: String,
        val alias: String = "",
        val adminUp: Boolean? = null,
        val operUp: Boolean? = null,
        val speedMbps: Long? = null,
        val inOctets: Long? = null,
        val outOctets: Long? = null,
        /** Whether the octet counters are 64-bit (ifHC*), which do not wrap in practice. */
        val wide: Boolean = false,
    ) {
        /** Switched on but not passing traffic: what an "interface down" alert means. */
        val down: Boolean get() = adminUp == true && operUp == false
    }

    enum class StorageKind { RAM, DISK, OTHER }

    data class Storage(val index: Int, val kind: StorageKind, val name: String, val totalBytes: Long, val usedBytes: Long) {
        val usedPercent: Float? get() = if (totalBytes > 0) usedBytes * 100f / totalBytes else null
    }

    data class Snapshot(
        val at: Long,
        val name: String,
        val description: String,
        val location: String = "",
        val contact: String = "",
        val uptimeSeconds: Long? = null,
        val cpuPercent: Float? = null,
        val interfaces: List<Interface> = emptyList(),
        val storage: List<Storage> = emptyList(),
    ) {
        val interfacesDown: List<Interface> get() = interfaces.filter { it.down }
    }

    sealed class Outcome {
        data class Answered(val snapshot: Snapshot) : Outcome()
        data class Failed(val reason: String) : Outcome()
    }

    // The standard objects read (RFC 3418 system, RFC 2863 IF-MIB, RFC 2790 HOST-RESOURCES-MIB).
    private const val SYS_DESCR = "1.3.6.1.2.1.1.1.0"
    private const val SYS_UPTIME = "1.3.6.1.2.1.1.3.0"
    private const val SYS_CONTACT = "1.3.6.1.2.1.1.4.0"
    private const val SYS_NAME = "1.3.6.1.2.1.1.5.0"
    private const val SYS_LOCATION = "1.3.6.1.2.1.1.6.0"
    private const val IF_DESCR = "1.3.6.1.2.1.2.2.1.2"
    private const val IF_SPEED = "1.3.6.1.2.1.2.2.1.5"
    private const val IF_ADMIN = "1.3.6.1.2.1.2.2.1.7"
    private const val IF_OPER = "1.3.6.1.2.1.2.2.1.8"
    private const val IF_IN = "1.3.6.1.2.1.2.2.1.10"
    private const val IF_OUT = "1.3.6.1.2.1.2.2.1.16"
    private const val IF_NAME = "1.3.6.1.2.1.31.1.1.1.1"
    private const val IF_HC_IN = "1.3.6.1.2.1.31.1.1.1.6"
    private const val IF_HC_OUT = "1.3.6.1.2.1.31.1.1.1.10"
    private const val IF_HIGH_SPEED = "1.3.6.1.2.1.31.1.1.1.15"
    private const val IF_ALIAS = "1.3.6.1.2.1.31.1.1.1.18"
    private const val HR_PROCESSOR_LOAD = "1.3.6.1.2.1.25.3.3.1.2"
    private const val HR_STORAGE_TYPE = "1.3.6.1.2.1.25.2.3.1.2"
    private const val HR_STORAGE_DESCR = "1.3.6.1.2.1.25.2.3.1.3"
    private const val HR_STORAGE_UNITS = "1.3.6.1.2.1.25.2.3.1.4"
    private const val HR_STORAGE_SIZE = "1.3.6.1.2.1.25.2.3.1.5"
    private const val HR_STORAGE_USED = "1.3.6.1.2.1.25.2.3.1.6"
    private const val HR_STORAGE_RAM = "1.3.6.1.2.1.25.2.1.2"
    private const val HR_STORAGE_FIXED_DISK = "1.3.6.1.2.1.25.2.1.4"
    private const val HR_STORAGE_NETWORK_DISK = "1.3.6.1.2.1.25.2.1.10"

    /** The columns walked, in the order [snapshot] reads them. */
    val COLUMNS: List<String> = listOf(
        IF_DESCR, IF_SPEED, IF_ADMIN, IF_OPER, IF_IN, IF_OUT, IF_NAME, IF_HC_IN, IF_HC_OUT, IF_HIGH_SPEED, IF_ALIAS,
        HR_PROCESSOR_LOAD, HR_STORAGE_TYPE, HR_STORAGE_DESCR, HR_STORAGE_UNITS, HR_STORAGE_SIZE, HR_STORAGE_USED,
    )
    val SYSTEM: List<String> = listOf(SYS_DESCR, SYS_UPTIME, SYS_CONTACT, SYS_NAME, SYS_LOCATION)

    // USM's report counters (RFC 3414): what a v3 agent answers instead when it refuses a request.
    // An agent sends them unauthenticated, and SNMP4J keeps to RFC 3412 §7.2.11 and drops such a
    // report for a wrong digest, so a wrong authentication password shows as no answer.
    private val REPORTS = mapOf(
        "1.3.6.1.6.3.15.1.1.1.0" to "the device does not allow that security level for this user",
        "1.3.6.1.6.3.15.1.1.2.0" to "the device's clock window refused the request; try again",
        "1.3.6.1.6.3.15.1.1.3.0" to "the device does not know this SNMPv3 user",
        "1.3.6.1.6.3.15.1.1.4.0" to "the device's engine ID could not be learnt",
        "1.3.6.1.6.3.15.1.1.5.0" to "the device refused the authentication password or protocol",
        "1.3.6.1.6.3.15.1.1.6.0" to "the device could not decrypt the request: check the privacy password and protocol",
    )

    /** Why a device answered with a report about [oid] (a USM counter) instead of the values. */
    fun reportReason(oid: String?): String = REPORTS[oid] ?: "the device refused the request ($oid)"

    /** What to say when a request got no answer in time. */
    fun noAnswer(access: Access): String =
        "no answer within ${TIMEOUT_MS / 1000} s: check the address, port, ${if (access.version == 3) "user and passwords" else "community"} and that UDP reaches it"

    /** What the device answered to [SYSTEM] and each walked column, as [snapshot] reads it. */
    fun snapshot(at: Long, system: Map<String, SnmpValue>, columns: Map<String, Map<Int, SnmpValue>>): Snapshot {
        fun text(oid: String) = system[oid]?.let(::readable).orEmpty()
        fun col(oid: String) = columns[oid].orEmpty()
        fun long(v: SnmpValue?): Long? = when (v) {
            is SnmpValue.Counter -> v.value
            is SnmpValue.Integer -> v.value.toLong()
            is SnmpValue.Ticks -> v.hundredths
            else -> null
        }
        fun status(v: SnmpValue?): Boolean? = (v as? SnmpValue.Integer)?.value?.let { it == 1 }
        val indexes = (col(IF_DESCR).keys + col(IF_NAME).keys).toSortedSet()
        val interfaces = indexes.map { i ->
            val hcIn = long(col(IF_HC_IN)[i])
            val hcOut = long(col(IF_HC_OUT)[i])
            val wide = hcIn != null && hcOut != null
            val highSpeed = long(col(IF_HIGH_SPEED)[i])?.takeIf { it > 0 }
            Interface(
                index = i,
                name = col(IF_NAME)[i]?.let(::readable)?.takeIf { it.isNotBlank() } ?: col(IF_DESCR)[i]?.let(::readable).orEmpty().ifBlank { "if$i" },
                alias = col(IF_ALIAS)[i]?.let(::readable).orEmpty(),
                adminUp = status(col(IF_ADMIN)[i]),
                operUp = status(col(IF_OPER)[i]),
                speedMbps = highSpeed ?: long(col(IF_SPEED)[i])?.takeIf { it > 0 }?.let { it / 1_000_000 },
                inOctets = if (wide) hcIn else long(col(IF_IN)[i]),
                outOctets = if (wide) hcOut else long(col(IF_OUT)[i]),
                wide = wide,
            )
        }
        val loads = col(HR_PROCESSOR_LOAD).values.mapNotNull { (it as? SnmpValue.Integer)?.value }
        val storage = col(HR_STORAGE_TYPE).mapNotNull { (i, type) ->
            val kind = when ((type as? SnmpValue.Oid)?.dotted) {
                HR_STORAGE_RAM -> StorageKind.RAM
                HR_STORAGE_FIXED_DISK, HR_STORAGE_NETWORK_DISK -> StorageKind.DISK
                else -> StorageKind.OTHER
            }
            val units = long(col(HR_STORAGE_UNITS)[i])?.takeIf { it > 0 } ?: return@mapNotNull null
            val size = long(col(HR_STORAGE_SIZE)[i])?.takeIf { it > 0 } ?: return@mapNotNull null
            val used = long(col(HR_STORAGE_USED)[i]) ?: return@mapNotNull null
            Storage(i, kind, col(HR_STORAGE_DESCR)[i]?.let(::readable).orEmpty(), size * units, used * units)
        }
        return Snapshot(
            at = at,
            name = text(SYS_NAME),
            description = text(SYS_DESCR),
            location = text(SYS_LOCATION),
            contact = text(SYS_CONTACT),
            uptimeSeconds = (system[SYS_UPTIME] as? SnmpValue.Ticks)?.hundredths?.let { it / 100 },
            cpuPercent = loads.takeIf { it.isNotEmpty() }?.average()?.toFloat(),
            interfaces = interfaces,
            storage = storage.filter { it.kind != StorageKind.OTHER },
        )
    }

    /** A value as text: an octet string as text when it is printable, else as hex (some devices send MACs). */
    private fun readable(v: SnmpValue): String = when (v) {
        is SnmpValue.Text -> {
            val bytes = v.bytes
            val printable = bytes.all { b -> b.toInt().let { it == 9 || it == 10 || it == 13 || it in 32..126 } || b < 0 }
            if (printable) bytes.decodeToString().trim().trimEnd('\u0000') else bytes.joinToString(":") { "%02x".format(it) }
        }
        is SnmpValue.Integer -> v.value.toString()
        is SnmpValue.Counter -> v.value.toString()
        is SnmpValue.Ticks -> v.hundredths.toString()
        is SnmpValue.Oid -> v.dotted
        is SnmpValue.Other -> v.text
        SnmpValue.Missing -> ""
    }

    /**
     * Bytes per second in and out of each interface between two snapshots, by index. A 32-bit
     * counter that went down wrapped once; a 64-bit one that went down was reset (a reboot), and
     * says nothing.
     */
    fun rates(previous: Snapshot?, current: Snapshot): Map<Int, Pair<Long, Long>> {
        previous ?: return emptyMap()
        val seconds = (current.at - previous.at) / 1000.0
        if (seconds <= 0.5) return emptyMap()
        val before = previous.interfaces.associateBy { it.index }
        return current.interfaces.mapNotNull { now ->
            val then = before[now.index] ?: return@mapNotNull null
            if (then.wide != now.wide) return@mapNotNull null
            fun delta(a: Long?, b: Long?): Long? {
                a ?: return null; b ?: return null
                return when {
                    b >= a -> b - a
                    !now.wide -> b + (1L shl 32) - a
                    else -> null
                }
            }
            val din = delta(then.inOctets, now.inOctets) ?: return@mapNotNull null
            val dout = delta(then.outOctets, now.outOctets) ?: return@mapNotNull null
            now.index to ((din / seconds).toLong() to (dout / seconds).toLong())
        }.toMap()
    }

    /** Polls one device with [engine]: its system group, then each column, in one session. */
    fun poll(access: Access, engine: SnmpEngine, now: () -> Long = System::currentTimeMillis): Outcome {
        problem(access)?.let { return Outcome.Failed(it) }
        return try {
            engine.open(access).use { session ->
                val system = when (val answer = session.get(SYSTEM)) {
                    is SnmpAnswer.Values -> answer.values
                    is SnmpAnswer.Refused -> return Outcome.Failed(answer.reason)
                }
                if (system.values.all { it == SnmpValue.Missing }) {
                    return Outcome.Failed("the device answered, but has no system information (an SNMP view without MIB-2?)")
                }
                val columns = COLUMNS.associateWith { session.walk(it, MAX_ROWS) }
                Outcome.Answered(snapshot(now(), system, columns))
            }
        } catch (e: SnmpFailure) {
            Outcome.Failed(e.message.orEmpty())
        }
    }
}

/** One value a device answered, whatever SNMP library read it. */
sealed interface SnmpValue {
    /** An OCTET STRING. */
    class Text(val bytes: ByteArray) : SnmpValue
    /** An INTEGER (enumerations such as ifOperStatus too). */
    data class Integer(val value: Int) : SnmpValue
    /** A Counter32, Counter64 or Gauge32. */
    data class Counter(val value: Long) : SnmpValue
    /** TimeTicks, in hundredths of a second. */
    data class Ticks(val hundredths: Long) : SnmpValue
    /** An OBJECT IDENTIFIER, dotted. */
    data class Oid(val dotted: String) : SnmpValue
    /** Any other type, as text. */
    data class Other(val text: String) : SnmpValue
    /** noSuchObject, noSuchInstance or endOfMibView. */
    data object Missing : SnmpValue
}

/** A GET's answer: the values by OID, or why the device refused. */
sealed class SnmpAnswer {
    data class Values(val values: Map<String, SnmpValue>) : SnmpAnswer()
    data class Refused(val reason: String) : SnmpAnswer()
}

/** A poll could not go on: [message] says why, in words for the user. */
class SnmpFailure(message: String) : Exception(message)

/**
 * One device's session: read-only by construction, since GET and a GETBULK walk are all it can do.
 * Throws [SnmpFailure] when a request cannot be sent.
 */
interface SnmpSession : AutoCloseable {
    /** A GET of [oids] (dotted). A request with no answer in time is [SnmpAnswer.Refused] with [SnmpDevices.noAnswer]. */
    fun get(oids: List<String>): SnmpAnswer

    /** Every row of [column], by its last sub-identifier, read with GETBULK; at most [maxRows], fewer when the device stops answering. */
    fun walk(column: String, maxRows: Int): Map<Int, SnmpValue>
}

/** The SNMP library: opens a session to a device. Throws [SnmpFailure] when it cannot. */
fun interface SnmpEngine {
    fun open(access: SnmpDevices.Access): SnmpSession
}

/** How to reach and sign in to [this] device. */
fun SnmpDeviceEntity.access() = SnmpDevices.Access(host, port, version, community, user, authProtocol, authPassword, privProtocol, privPassword)
