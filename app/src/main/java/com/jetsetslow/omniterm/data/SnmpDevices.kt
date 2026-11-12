package com.jetsetslow.omniterm.data

import org.snmp4j.CommunityTarget
import org.snmp4j.MessageDispatcherImpl
import org.snmp4j.PDU
import org.snmp4j.ScopedPDU
import org.snmp4j.Snmp
import org.snmp4j.Target
import org.snmp4j.UserTarget
import org.snmp4j.mp.MPv2c
import org.snmp4j.mp.MPv3
import org.snmp4j.mp.SnmpConstants
import org.snmp4j.security.AuthHMAC128SHA224
import org.snmp4j.security.AuthHMAC192SHA256
import org.snmp4j.security.AuthHMAC256SHA384
import org.snmp4j.security.AuthHMAC384SHA512
import org.snmp4j.security.AuthMD5
import org.snmp4j.security.AuthSHA
import org.snmp4j.security.PrivAES128
import org.snmp4j.security.PrivAES192
import org.snmp4j.security.PrivAES256
import org.snmp4j.security.PrivDES
import org.snmp4j.security.SecurityLevel
import org.snmp4j.security.SecurityProtocols
import org.snmp4j.security.USM
import org.snmp4j.security.UsmUser
import org.snmp4j.smi.Address
import org.snmp4j.smi.Counter32
import org.snmp4j.smi.Counter64
import org.snmp4j.smi.Gauge32
import org.snmp4j.smi.Integer32
import org.snmp4j.smi.OID
import org.snmp4j.smi.OctetString
import org.snmp4j.smi.TimeTicks
import org.snmp4j.smi.UdpAddress
import org.snmp4j.smi.Variable
import org.snmp4j.smi.VariableBinding
import org.snmp4j.transport.DefaultUdpTransportMapping
import java.net.InetAddress

/**
 * SNMP devices (switches, routers, UPSes, printers, NAS boxes) polled from the phone over UDP,
 * with SNMP v2c or v3. Read-only: every request goes through [send], which allows only GET and
 * GETBULK, so nothing on a device can be changed from here. The v3 security (USM) is SNMP4J's,
 * on the JDK's own digests and ciphers.
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

    /** The only request types this app sends. There is no SET anywhere. */
    val READ_ONLY_PDU_TYPES = setOf(PDU.GET, PDU.GETBULK)

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
    private val SYS_DESCR = OID("1.3.6.1.2.1.1.1.0")
    private val SYS_UPTIME = OID("1.3.6.1.2.1.1.3.0")
    private val SYS_CONTACT = OID("1.3.6.1.2.1.1.4.0")
    private val SYS_NAME = OID("1.3.6.1.2.1.1.5.0")
    private val SYS_LOCATION = OID("1.3.6.1.2.1.1.6.0")
    private val IF_DESCR = OID("1.3.6.1.2.1.2.2.1.2")
    private val IF_SPEED = OID("1.3.6.1.2.1.2.2.1.5")
    private val IF_ADMIN = OID("1.3.6.1.2.1.2.2.1.7")
    private val IF_OPER = OID("1.3.6.1.2.1.2.2.1.8")
    private val IF_IN = OID("1.3.6.1.2.1.2.2.1.10")
    private val IF_OUT = OID("1.3.6.1.2.1.2.2.1.16")
    private val IF_NAME = OID("1.3.6.1.2.1.31.1.1.1.1")
    private val IF_HC_IN = OID("1.3.6.1.2.1.31.1.1.1.6")
    private val IF_HC_OUT = OID("1.3.6.1.2.1.31.1.1.1.10")
    private val IF_HIGH_SPEED = OID("1.3.6.1.2.1.31.1.1.1.15")
    private val IF_ALIAS = OID("1.3.6.1.2.1.31.1.1.1.18")
    private val HR_PROCESSOR_LOAD = OID("1.3.6.1.2.1.25.3.3.1.2")
    private val HR_STORAGE_TYPE = OID("1.3.6.1.2.1.25.2.3.1.2")
    private val HR_STORAGE_DESCR = OID("1.3.6.1.2.1.25.2.3.1.3")
    private val HR_STORAGE_UNITS = OID("1.3.6.1.2.1.25.2.3.1.4")
    private val HR_STORAGE_SIZE = OID("1.3.6.1.2.1.25.2.3.1.5")
    private val HR_STORAGE_USED = OID("1.3.6.1.2.1.25.2.3.1.6")
    private val HR_STORAGE_RAM = OID("1.3.6.1.2.1.25.2.1.2")
    private val HR_STORAGE_FIXED_DISK = OID("1.3.6.1.2.1.25.2.1.4")
    private val HR_STORAGE_NETWORK_DISK = OID("1.3.6.1.2.1.25.2.1.10")

    /** The columns walked, in the order [snapshot] reads them. */
    val COLUMNS: List<OID> = listOf(
        IF_DESCR, IF_SPEED, IF_ADMIN, IF_OPER, IF_IN, IF_OUT, IF_NAME, IF_HC_IN, IF_HC_OUT, IF_HIGH_SPEED, IF_ALIAS,
        HR_PROCESSOR_LOAD, HR_STORAGE_TYPE, HR_STORAGE_DESCR, HR_STORAGE_UNITS, HR_STORAGE_SIZE, HR_STORAGE_USED,
    )
    val SYSTEM: List<OID> = listOf(SYS_DESCR, SYS_UPTIME, SYS_CONTACT, SYS_NAME, SYS_LOCATION)

    // USM's report counters (RFC 3414): what a v3 agent answers instead when it refuses a request.
    // An agent sends them unauthenticated, and SNMP4J keeps to RFC 3412 §7.2.11 and drops such a
    // report for a wrong digest, so a wrong authentication password shows as no answer.
    private val REPORTS = mapOf(
        OID("1.3.6.1.6.3.15.1.1.1.0") to "the device does not allow that security level for this user",
        OID("1.3.6.1.6.3.15.1.1.2.0") to "the device's clock window refused the request; try again",
        OID("1.3.6.1.6.3.15.1.1.3.0") to "the device does not know this SNMPv3 user",
        OID("1.3.6.1.6.3.15.1.1.4.0") to "the device's engine ID could not be learnt",
        OID("1.3.6.1.6.3.15.1.1.5.0") to "the device refused the authentication password or protocol",
        OID("1.3.6.1.6.3.15.1.1.6.0") to "the device could not decrypt the request: check the privacy password and protocol",
    )

    /** What the device answered to [system] and each walked column, as [snapshot] reads it. */
    fun snapshot(at: Long, system: Map<OID, Variable>, columns: Map<OID, Map<Int, Variable>>): Snapshot {
        fun text(oid: OID) = system[oid]?.takeUnless { it.isException }?.let(::readable).orEmpty()
        fun col(oid: OID) = columns[oid].orEmpty()
        fun long(v: Variable?): Long? = when (v) {
            is Counter64 -> v.value
            is Counter32 -> v.value
            is Gauge32 -> v.value
            is Integer32 -> v.value.toLong()
            is TimeTicks -> v.value
            else -> null
        }
        fun status(v: Variable?): Boolean? = (v as? Integer32)?.value?.let { it == 1 }
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
        val loads = col(HR_PROCESSOR_LOAD).values.mapNotNull { (it as? Integer32)?.value }
        val storage = col(HR_STORAGE_TYPE).mapNotNull { (i, type) ->
            val kind = when (type as? OID) {
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
            uptimeSeconds = (system[SYS_UPTIME] as? TimeTicks)?.value?.let { it / 100 },
            cpuPercent = loads.takeIf { it.isNotEmpty() }?.average()?.toFloat(),
            interfaces = interfaces,
            storage = storage.filter { it.kind != StorageKind.OTHER },
        )
    }

    /** An octet string as text when it is printable, else as hex (some devices send MACs). */
    private fun readable(v: Variable): String {
        val s = v as? OctetString ?: return v.toString()
        val bytes = s.value
        val printable = bytes.all { b -> b.toInt().let { it == 9 || it == 10 || it == 13 || it in 32..126 } || b < 0 }
        return if (printable) String(bytes, Charsets.UTF_8).trim().trimEnd('\u0000') else s.toHexString()
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

    /** Polls one device: its system group, then each column, over one UDP socket. */
    fun poll(access: Access, now: () -> Long = System::currentTimeMillis): Outcome {
        problem(access)?.let { return Outcome.Failed(it) }
        val address = runCatching { InetAddress.getByName(access.host.trim().removeSurrounding("[", "]")) }.getOrNull()
            ?: return Outcome.Failed("${access.host} could not be resolved")
        val target = UdpAddress(address, access.port)
        val transport = DefaultUdpTransportMapping()
        val dispatcher = MessageDispatcherImpl()
        dispatcher.addMessageProcessingModel(MPv2c())
        var usm: USM? = null
        if (access.version == 3) {
            val protocols = SecurityProtocols(SecurityProtocols.SecurityProtocolSet.none)
            listOf(AuthMD5(), AuthSHA(), AuthHMAC128SHA224(), AuthHMAC192SHA256(), AuthHMAC256SHA384(), AuthHMAC384SHA512())
                .forEach(protocols::addAuthenticationProtocol)
            listOf(PrivDES(), PrivAES128(), PrivAES192(), PrivAES256()).forEach(protocols::addPrivacyProtocol)
            usm = USM(protocols, OctetString(MPv3.createLocalEngineID()), 0).also {
                it.addUser(user(access))
                dispatcher.addMessageProcessingModel(MPv3(it))
            }
        }
        val snmp = Snmp(dispatcher, transport)
        return try {
            snmp.listen()
            val tgt = target(access, target)
            val system = when (val answer = send(snmp, tgt, pdu(access, PDU.GET).apply { SYSTEM.forEach { add(VariableBinding(it)) } })) {
                is Answer.Bindings -> answer.bindings.associate { it.oid to it.variable }
                is Answer.Refused -> return Outcome.Failed(answer.reason)
            }
            if (system.values.all { it.isException }) return Outcome.Failed("the device answered, but has no system information (an SNMP view without MIB-2?)")
            val columns = COLUMNS.associateWith { walk(snmp, tgt, access, it) }
            Outcome.Answered(snapshot(now(), system, columns))
        } catch (e: java.io.IOException) {
            Outcome.Failed("the request could not be sent (${e.message ?: e.javaClass.simpleName})")
        } finally {
            runCatching { snmp.close() }
            usm?.removeAllUsers()
        }
    }

    private fun user(access: Access) = UsmUser(
        OctetString(access.user),
        authId(access.authProtocol), access.authPassword.takeIf { access.authProtocol.isNotEmpty() }?.let(::OctetString),
        privId(access.privProtocol), access.privPassword.takeIf { access.privProtocol.isNotEmpty() }?.let(::OctetString),
    )

    private fun authId(name: String): OID? = when (name) {
        "MD5" -> AuthMD5.ID
        "SHA" -> AuthSHA.ID
        "SHA-224" -> AuthHMAC128SHA224.ID
        "SHA-256" -> AuthHMAC192SHA256.ID
        "SHA-384" -> AuthHMAC256SHA384.ID
        "SHA-512" -> AuthHMAC384SHA512.ID
        else -> null
    }

    private fun privId(name: String): OID? = when (name) {
        "DES" -> PrivDES.ID
        "AES" -> PrivAES128.ID
        "AES-192" -> PrivAES192.ID
        "AES-256" -> PrivAES256.ID
        else -> null
    }

    private fun target(access: Access, address: UdpAddress): Target<Address> {
        @Suppress("UNCHECKED_CAST")
        val t = if (access.version == 3) {
            UserTarget<UdpAddress>().apply {
                securityName = OctetString(access.user)
                securityLevel = when {
                    access.privProtocol.isNotEmpty() -> SecurityLevel.AUTH_PRIV
                    access.authProtocol.isNotEmpty() -> SecurityLevel.AUTH_NOPRIV
                    else -> SecurityLevel.NOAUTH_NOPRIV
                }
                version = SnmpConstants.version3
            }
        } else {
            CommunityTarget<UdpAddress>().apply {
                community = OctetString(access.community)
                version = SnmpConstants.version2c
            }
        }
        t.address = address
        t.timeout = TIMEOUT_MS
        t.retries = RETRIES
        @Suppress("UNCHECKED_CAST")
        return t as Target<Address>
    }

    private fun pdu(access: Access, type: Int): PDU = (if (access.version == 3) ScopedPDU() else PDU()).apply { this.type = type }

    private sealed class Answer {
        data class Bindings(val bindings: List<VariableBinding>) : Answer()
        data class Refused(val reason: String) : Answer()
    }

    /** The one place a request leaves the phone: GET and GETBULK only. */
    private fun send(snmp: Snmp, target: Target<Address>, pdu: PDU): Answer {
        require(pdu.type in READ_ONLY_PDU_TYPES) { "SNMP is read-only in OmniTerm" }
        val response = snmp.send(pdu, target)?.response
            ?: return Answer.Refused("no answer within ${TIMEOUT_MS / 1000} s: check the address, port, ${if (target is CommunityTarget<*>) "community" else "user and passwords"} and that UDP reaches it")
        if (response.type == PDU.REPORT) {
            val oid = response.variableBindings.firstOrNull()?.oid
            return Answer.Refused(REPORTS[oid] ?: "the device refused the request ($oid)")
        }
        if (response.errorStatus != PDU.noError) return Answer.Refused("the device answered ${response.errorStatusText}")
        return Answer.Bindings(response.variableBindings.toList())
    }

    /** Every row of one column, by its last sub-identifier, read with GETBULK. */
    private fun walk(snmp: Snmp, target: Target<Address>, access: Access, column: OID): Map<Int, Variable> {
        val rows = linkedMapOf<Int, Variable>()
        var next = column
        while (rows.size < MAX_ROWS) {
            val request = pdu(access, PDU.GETBULK).apply {
                add(VariableBinding(next))
                nonRepeaters = 0
                maxRepetitions = 25
            }
            val bindings = (send(snmp, target, request) as? Answer.Bindings)?.bindings ?: break
            var more = false
            for (b in bindings) {
                if (b.isException || !b.oid.startsWith(column) || b.oid.size() != column.size() + 1) { more = false; break }
                rows[b.oid.last()] = b.variable
                next = b.oid
                more = true
            }
            if (!more || bindings.isEmpty()) break
        }
        return rows
    }
}

/** How to reach and sign in to [this] device. */
fun SnmpDeviceEntity.access() = SnmpDevices.Access(host, port, version, community, user, authProtocol, authPassword, privProtocol, privPassword)
