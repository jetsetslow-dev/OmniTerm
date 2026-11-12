package com.jetsetslow.omniterm

import com.jetsetslow.omniterm.data.Snmp4jEngine
import com.jetsetslow.omniterm.data.SnmpAnswer
import com.jetsetslow.omniterm.data.SnmpDevices
import com.jetsetslow.omniterm.data.SnmpDevices.Access
import com.jetsetslow.omniterm.data.SnmpDevices.Outcome
import com.jetsetslow.omniterm.data.SnmpDevices.StorageKind
import com.jetsetslow.omniterm.data.SnmpEngine
import com.jetsetslow.omniterm.data.SnmpFailure
import com.jetsetslow.omniterm.data.SnmpSession
import com.jetsetslow.omniterm.data.SnmpValue
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.snmp4j.CommandResponder
import org.snmp4j.CommandResponderEvent
import org.snmp4j.MessageDispatcherImpl
import org.snmp4j.PDU
import org.snmp4j.ScopedPDU
import org.snmp4j.Snmp
import org.snmp4j.mp.MPv2c
import org.snmp4j.mp.MPv3
import org.snmp4j.mp.StatusInformation
import org.snmp4j.security.AuthHMAC192SHA256
import org.snmp4j.security.AuthSHA
import org.snmp4j.security.PrivAES128
import org.snmp4j.security.SecurityModel
import org.snmp4j.security.SecurityProtocols
import org.snmp4j.security.USM
import org.snmp4j.security.UsmUser
import org.snmp4j.smi.Address
import org.snmp4j.smi.Counter32
import org.snmp4j.smi.Counter64
import org.snmp4j.smi.Gauge32
import org.snmp4j.smi.Integer32
import org.snmp4j.smi.Null
import org.snmp4j.smi.OID
import org.snmp4j.smi.OctetString
import org.snmp4j.smi.TimeTicks
import org.snmp4j.smi.UdpAddress
import org.snmp4j.smi.Variable
import org.snmp4j.smi.VariableBinding
import org.snmp4j.transport.DefaultUdpTransportMapping
import java.util.TreeMap
import java.util.concurrent.CopyOnWriteArrayList

/**
 * SNMP polling against a small agent run in this test on 127.0.0.1 (SNMP4J's own responder), so
 * v2c and v3 are exercised end to end with no service on the machine. The agent records every
 * request type it receives: the poller must only ever send GET and GETBULK.
 */
class SnmpDevicesTest {
    private val community = "fixture-community"
    private val authPass = "fixture-auth-pass"
    private val privPass = "fixture-priv-pass"
    private val agent = Agent()

    @After fun stop() = agent.close()

    @Test
    fun aV2cDeviceIsReadIntoItsSystemInterfacesCpuAndStorage() {
        val outcome = SnmpDevices.poll(Access("127.0.0.1", agent.port, 2, community = community), Snmp4jEngine, now = { 1_000L })
        val snap = (outcome as Outcome.Answered).snapshot
        assertEquals("sw1", snap.name)
        assertEquals("Fixture switch", snap.description)
        assertEquals("Rack 2", snap.location)
        assertEquals(1234L, snap.uptimeSeconds)
        assertEquals(20f, snap.cpuPercent)
        val (uplink, spare) = snap.interfaces
        assertEquals("ge-0/0/1", uplink.name)
        assertEquals("to the NAS", uplink.alias)
        assertTrue(uplink.wide)
        assertEquals(5_000_000_000L, uplink.inOctets)
        assertEquals(1000L, uplink.speedMbps)
        assertFalse(uplink.down)
        assertEquals("eth2", spare.name)
        assertTrue("switched on, no link", spare.down)
        assertEquals(100L, spare.speedMbps)
        assertEquals(listOf(spare), snap.interfacesDown)
        assertEquals(listOf(StorageKind.RAM, StorageKind.DISK), snap.storage.map { it.kind })
        assertEquals(50f, snap.storage[0].usedPercent)
        assertEquals(4096L * 100, snap.storage[1].totalBytes)
        assertEquals("only reads", setOf(PDU.GET, PDU.GETBULK), agent.seen.toSet())
        assertTrue("reads whole columns over several bulk requests", agent.seen.count { it == PDU.GETBULK } >= SnmpDevices.COLUMNS.size)
    }

    @Test
    fun aV3DeviceIsReadWithAuthenticationAndPrivacy() {
        val access = Access("127.0.0.1", agent.port, 3, user = "monitor", authProtocol = "SHA-256", authPassword = authPass, privProtocol = "AES", privPassword = privPass)
        val snap = (SnmpDevices.poll(access, Snmp4jEngine) as Outcome.Answered).snapshot
        assertEquals("sw1", snap.name)
        assertEquals(2, snap.interfaces.size)
        assertEquals(setOf(PDU.GET, PDU.GETBULK), agent.seen.toSet())
        assertTrue("every v3 read came through USM", agent.models.all { it == SecurityModel.SECURITY_MODEL_USM })
    }

    @Test
    fun eachWayOfBeingRefusedSaysWhy() {
        fun reason(access: Access) = (SnmpDevices.poll(access, Snmp4jEngine) as Outcome.Failed).reason
        assertTrue(reason(Access("127.0.0.1", agent.port, 2, community = "wrong")).startsWith("no answer within 3 s: check the address, port, community"))
        val v3 = Access("127.0.0.1", agent.port, 3, user = "monitor", authProtocol = "SHA-256", authPassword = authPass, privProtocol = "AES", privPassword = privPass)
        // SNMP4J's responder drops these silently; net-snmp answers with a USM report, whose
        // wording E2eSnmpDevicesTest reads against the fixture.
        assertTrue(reason(v3.copy(user = "stranger")).startsWith("no answer within 3 s: check the address, port, user and passwords"))
        assertTrue(reason(v3.copy(authPassword = "not-the-password")).startsWith("no answer"))
        assertEquals("Enter the community", reason(Access("127.0.0.1", agent.port, 2)))
        assertEquals("The privacy password needs at least 8 characters", reason(v3.copy(privPassword = "short")))
        assertEquals("Privacy needs authentication too", SnmpDevices.problem(v3.copy(authProtocol = "")))
        assertNull(SnmpDevices.problem(v3))
        assertFalse("a refused request is never retried as a write", PDU.SET in agent.seen)
    }

    @Test
    fun theFeatureNeedsOnlyThePlainEngineInterface() {
        // What another SNMP engine (the Go core on iOS, say) has to provide: plain OIDs and values.
        val asked = mutableListOf<String>()
        val engine = SnmpEngine {
            object : SnmpSession {
                override fun get(oids: List<String>): SnmpAnswer {
                    asked += "get"
                    return SnmpAnswer.Values(mapOf("1.3.6.1.2.1.1.5.0" to SnmpValue.Text("sw9".toByteArray()), "1.3.6.1.2.1.1.3.0" to SnmpValue.Ticks(500)))
                }

                override fun walk(column: String, maxRows: Int): Map<Int, SnmpValue> {
                    asked += column
                    return if (column == "1.3.6.1.2.1.2.2.1.2") mapOf(3 to SnmpValue.Text(byteArrayOf(0, 0x1b, 0x21, 0x3a, 0x4b, 0x5c))) else emptyMap()
                }

                override fun close() { asked += "close" }
            }
        }
        val snap = (SnmpDevices.poll(Access("192.0.2.9", community = "c"), engine) as Outcome.Answered).snapshot
        assertEquals("sw9", snap.name)
        assertEquals(5L, snap.uptimeSeconds)
        assertEquals("bytes that are not text show as hex, as a MAC does", "00:1b:21:3a:4b:5c", snap.interfaces.single().name)
        assertEquals("one session: the system group, every column, then closed", listOf("get") + SnmpDevices.COLUMNS + "close", asked)
        val unreachable = SnmpEngine { throw SnmpFailure("192.0.2.9 could not be resolved") }
        assertEquals(Outcome.Failed("192.0.2.9 could not be resolved"), SnmpDevices.poll(Access("192.0.2.9", community = "c"), unreachable))
        assertEquals("the SNMP4J engine sends nothing but reads", setOf(PDU.GET, PDU.GETBULK), Snmp4jEngine.READ_ONLY_PDU_TYPES)
    }

    @Test
    fun ratesAreBytesPerSecondAndSurviveA32BitWrap() {
        val base = SnmpDevices.Snapshot(0L, "d", "d", interfaces = listOf(
            SnmpDevices.Interface(1, "a", inOctets = 1_000, outOctets = 2_000, wide = true),
            SnmpDevices.Interface(2, "b", inOctets = 4_294_967_000L, outOctets = 10, wide = false),
            SnmpDevices.Interface(3, "c", inOctets = 900, outOctets = 900, wide = true),
        ))
        val later = base.copy(at = 10_000L, interfaces = listOf(
            SnmpDevices.Interface(1, "a", inOctets = 11_000, outOctets = 2_000, wide = true),
            SnmpDevices.Interface(2, "b", inOctets = 704, outOctets = 1_010, wide = false),
            SnmpDevices.Interface(3, "c", inOctets = 100, outOctets = 100, wide = true),
        ))
        val rates = SnmpDevices.rates(base, later)
        assertEquals(1_000L to 0L, rates[1])
        assertEquals("one wrap of a 32-bit counter", 100L to 100L, rates[2])
        assertNull("a 64-bit counter that went down was reset", rates[3])
        assertTrue(SnmpDevices.rates(null, later).isEmpty())
    }

    /** A read-only agent answering GET and GETBULK from [mib], with a v2c community and one v3 user. */
    private inner class Agent : CommandResponder {
        val seen = CopyOnWriteArrayList<Int>()
        val models = CopyOnWriteArrayList<Int>()
        private val mib = TreeMap<OID, Variable>().apply {
            put(OID("1.3.6.1.2.1.1.1.0"), OctetString("Fixture switch"))
            put(OID("1.3.6.1.2.1.1.3.0"), TimeTicks(123_456))
            put(OID("1.3.6.1.2.1.1.4.0"), OctetString("ops@example.invalid"))
            put(OID("1.3.6.1.2.1.1.5.0"), OctetString("sw1"))
            put(OID("1.3.6.1.2.1.1.6.0"), OctetString("Rack 2"))
            for ((i, descr) in listOf(1 to "GigabitEthernet1", 2 to "eth2")) put(OID("1.3.6.1.2.1.2.2.1.2.$i"), OctetString(descr))
            put(OID("1.3.6.1.2.1.2.2.1.5.1"), Gauge32(1_000_000_000))
            put(OID("1.3.6.1.2.1.2.2.1.5.2"), Gauge32(100_000_000))
            put(OID("1.3.6.1.2.1.2.2.1.7.1"), Integer32(1)); put(OID("1.3.6.1.2.1.2.2.1.7.2"), Integer32(1))
            put(OID("1.3.6.1.2.1.2.2.1.8.1"), Integer32(1)); put(OID("1.3.6.1.2.1.2.2.1.8.2"), Integer32(2))
            put(OID("1.3.6.1.2.1.2.2.1.10.1"), Counter32(705_032_704)); put(OID("1.3.6.1.2.1.2.2.1.10.2"), Counter32(10))
            put(OID("1.3.6.1.2.1.2.2.1.16.1"), Counter32(5)); put(OID("1.3.6.1.2.1.2.2.1.16.2"), Counter32(20))
            put(OID("1.3.6.1.2.1.31.1.1.1.1.1"), OctetString("ge-0/0/1")); put(OID("1.3.6.1.2.1.31.1.1.1.1.2"), OctetString(""))
            put(OID("1.3.6.1.2.1.31.1.1.1.6.1"), Counter64(5_000_000_000L))
            put(OID("1.3.6.1.2.1.31.1.1.1.10.1"), Counter64(7_000_000_000L))
            put(OID("1.3.6.1.2.1.31.1.1.1.15.1"), Gauge32(1000))
            put(OID("1.3.6.1.2.1.31.1.1.1.18.1"), OctetString("to the NAS"))
            put(OID("1.3.6.1.2.1.25.3.3.1.2.196608"), Integer32(10)); put(OID("1.3.6.1.2.1.25.3.3.1.2.196609"), Integer32(30))
            val types = listOf(1 to "1.3.6.1.2.1.25.2.1.2", 31 to "1.3.6.1.2.1.25.2.1.4", 40 to "1.3.6.1.2.1.25.2.1.3")
            for ((i, type) in types) put(OID("1.3.6.1.2.1.25.2.3.1.2.$i"), OID(type))
            for ((i, d) in listOf(1 to "Physical memory", 31 to "/", 40 to "Virtual memory")) put(OID("1.3.6.1.2.1.25.2.3.1.3.$i"), OctetString(d))
            for ((i, u) in listOf(1 to 1024, 31 to 4096, 40 to 1024)) put(OID("1.3.6.1.2.1.25.2.3.1.4.$i"), Integer32(u))
            for ((i, s) in listOf(1 to 1000, 31 to 100, 40 to 10)) put(OID("1.3.6.1.2.1.25.2.3.1.5.$i"), Integer32(s))
            for ((i, u) in listOf(1 to 500, 31 to 25, 40 to 1)) put(OID("1.3.6.1.2.1.25.2.3.1.6.$i"), Integer32(u))
        }
        private val snmp: Snmp
        val port: Int

        init {
            val transport = DefaultUdpTransportMapping(UdpAddress("127.0.0.1/0"))
            val dispatcher = MessageDispatcherImpl()
            dispatcher.addMessageProcessingModel(MPv2c())
            val protocols = SecurityProtocols(SecurityProtocols.SecurityProtocolSet.none).apply {
                addAuthenticationProtocol(AuthSHA()); addAuthenticationProtocol(AuthHMAC192SHA256()); addPrivacyProtocol(PrivAES128())
            }
            val engine = OctetString(MPv3.createLocalEngineID(OctetString("omniterm-test-agent")))
            val usm = USM(protocols, engine, 0)
            usm.addUser(OctetString("monitor"), engine, UsmUser(OctetString("monitor"), AuthHMAC192SHA256.ID, OctetString(authPass), PrivAES128.ID, OctetString(privPass)))
            dispatcher.addMessageProcessingModel(MPv3(usm))
            snmp = Snmp(dispatcher, transport)
            snmp.addCommandResponder(this)
            snmp.listen()
            port = transport.listenAddress.port
        }

        fun close() = snmp.close()

        override fun <A : Address> processPdu(event: CommandResponderEvent<A>) {
            val pdu = event.pdu ?: return
            if (event.messageProcessingModel == 1 && OctetString(event.securityName) != OctetString(community)) return
            seen += pdu.type
            if (event.messageProcessingModel == 3) models += event.securityModel
            val bindings = when (pdu.type) {
                PDU.GET -> pdu.variableBindings.map { VariableBinding(it.oid, mib[it.oid] ?: Null.noSuchObject) }
                PDU.GETBULK -> pdu.variableBindings.flatMap { start ->
                    mib.tailMap(start.oid, false).entries.take(pdu.maxRepetitions).map { VariableBinding(it.key, it.value) }
                        .ifEmpty { listOf(VariableBinding(start.oid, Null.endOfMibView)) }
                }
                else -> return
            }
            val response = (if (pdu is ScopedPDU) ScopedPDU(pdu) else PDU(pdu)).apply {
                type = PDU.RESPONSE
                errorStatus = 0
                errorIndex = 0
                setVariableBindings(bindings)
            }
            event.messageDispatcher.returnResponsePdu(
                event.messageProcessingModel, event.securityModel, event.securityName, event.securityLevel,
                response, event.maxSizeResponsePDU, event.stateReference, StatusInformation(),
            )
            event.isProcessed = true
        }
    }
}
