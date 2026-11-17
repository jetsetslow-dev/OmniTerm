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
import java.io.IOException
import java.net.InetAddress

/**
 * [SnmpEngine] on SNMP4J, the only file that uses it. Each session has its own dispatcher, USM
 * and UDP socket. v3 security is SNMP4J's, on the JDK's own digests and ciphers. Every request
 * goes through [Session.send], which allows only GET and GETBULK.
 */
object Snmp4jEngine : SnmpEngine {
    /** The only request types this engine sends. There is no SET anywhere. */
    val READ_ONLY_PDU_TYPES = setOf(PDU.GET, PDU.GETBULK)

    override fun open(access: SnmpDevices.Access): SnmpSession {
        val address = runCatching { InetAddress.getByName(access.host.trim().removeSurrounding("[", "]")) }.getOrNull()
            ?: throw SnmpFailure("${access.host} could not be resolved")
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
        val transport = try {
            DefaultUdpTransportMapping()
        } catch (e: IOException) {
            usm?.removeAllUsers()
            throw unsent(e)
        }
        val snmp = Snmp(dispatcher, transport)
        try {
            snmp.listen()
        } catch (e: IOException) {
            runCatching { snmp.close() }
            usm?.removeAllUsers()
            throw unsent(e)
        }
        return Session(snmp, usm, access, target(access, UdpAddress(address, access.port)))
    }

    private fun unsent(e: IOException) = SnmpFailure("the request could not be sent (${e.message ?: e.javaClass.simpleName})")

    private class Session(
        private val snmp: Snmp,
        private val usm: USM?,
        private val access: SnmpDevices.Access,
        private val target: Target<Address>,
    ) : SnmpSession {
        override fun get(oids: List<String>): SnmpAnswer =
            when (val answer = send(pdu(PDU.GET).apply { oids.forEach { add(VariableBinding(OID(it))) } })) {
                is Answer.Bindings -> SnmpAnswer.Values(answer.bindings.associate { it.oid.toDottedString() to value(it.variable) })
                is Answer.Refused -> SnmpAnswer.Refused(answer.reason)
            }

        override fun walk(column: String, maxRows: Int): Map<Int, SnmpValue> {
            val root = OID(column)
            val rows = linkedMapOf<Int, SnmpValue>()
            var next = root
            while (rows.size < maxRows) {
                val request = pdu(PDU.GETBULK).apply {
                    add(VariableBinding(next))
                    nonRepeaters = 0
                    maxRepetitions = 25
                }
                val bindings = (send(request) as? Answer.Bindings)?.bindings ?: break
                var more = false
                for (b in bindings) {
                    if (b.isException || !b.oid.startsWith(root) || b.oid.size() != root.size() + 1) { more = false; break }
                    rows[b.oid.last()] = value(b.variable)
                    next = b.oid
                    more = true
                }
                if (!more || bindings.isEmpty()) break
            }
            return rows
        }

        override fun close() {
            runCatching { snmp.close() }
            usm?.removeAllUsers()
        }

        private fun pdu(type: Int): PDU = (if (access.version == 3) ScopedPDU() else PDU()).apply { this.type = type }

        /** The one place a request leaves the phone: GET and GETBULK only. */
        private fun send(pdu: PDU): Answer {
            require(pdu.type in READ_ONLY_PDU_TYPES) { "SNMP is read-only in OmniTerm" }
            val response = try {
                snmp.send(pdu, target)?.response
            } catch (e: IOException) {
                throw unsent(e)
            } ?: return Answer.Refused(SnmpDevices.noAnswer(access))
            if (response.type == PDU.REPORT) return Answer.Refused(SnmpDevices.reportReason(response.variableBindings.firstOrNull()?.oid?.toDottedString()))
            if (response.errorStatus != PDU.noError) return Answer.Refused("the device answered ${response.errorStatusText}")
            return Answer.Bindings(response.variableBindings.toList())
        }
    }

    private sealed class Answer {
        data class Bindings(val bindings: List<VariableBinding>) : Answer()
        data class Refused(val reason: String) : Answer()
    }

    /** SNMP4J's value as a plain [SnmpValue]. */
    private fun value(v: Variable): SnmpValue = when {
        v.isException -> SnmpValue.Missing
        v is OctetString -> SnmpValue.Text(v.value)
        v is Counter64 -> SnmpValue.Counter(v.value)
        v is Counter32 -> SnmpValue.Counter(v.value)
        v is Gauge32 -> SnmpValue.Counter(v.value)
        v is TimeTicks -> SnmpValue.Ticks(v.value)
        v is Integer32 -> SnmpValue.Integer(v.value)
        v is OID -> SnmpValue.Oid(v.toDottedString())
        else -> SnmpValue.Other(v.toString())
    }

    private fun user(access: SnmpDevices.Access) = UsmUser(
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

    private fun target(access: SnmpDevices.Access, address: UdpAddress): Target<Address> {
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
        t.timeout = SnmpDevices.TIMEOUT_MS
        t.retries = SnmpDevices.RETRIES
        @Suppress("UNCHECKED_CAST")
        return t as Target<Address>
    }
}
