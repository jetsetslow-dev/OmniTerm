package com.jetsetslow.omniterm

import com.jetsetslow.omniterm.data.AlertSubjects
import com.jetsetslow.omniterm.data.DeviceChecks
import com.jetsetslow.omniterm.data.Proxmox
import com.jetsetslow.omniterm.data.SnmpDevices
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** What the device alert rules read from an SNMP poll or a Proxmox VE overview, and how a device is named as an alert's subject. */
class DeviceChecksTest {
    @Test
    fun aDeviceSubjectIsNeverAHostIdAndKeepsItsKind() {
        for (id in listOf(1, 2, 7, 4096)) {
            assertEquals(AlertSubjects.Kind.SNMP, AlertSubjects.kind(AlertSubjects.snmp(id)))
            assertEquals(AlertSubjects.Kind.PROXMOX, AlertSubjects.kind(AlertSubjects.proxmox(id)))
            assertEquals(id, AlertSubjects.deviceId(AlertSubjects.snmp(id)))
            assertEquals(id, AlertSubjects.deviceId(AlertSubjects.proxmox(id)))
            assertTrue("below 0, so no host query matches it", AlertSubjects.snmp(id) < 0 && AlertSubjects.proxmox(id) < 0)
        }
        assertTrue("an SNMP device and a Proxmox server with the same id differ", AlertSubjects.snmp(3) != AlertSubjects.proxmox(3))
        assertEquals(AlertSubjects.Kind.HOST, AlertSubjects.kind(5))
        assertEquals(AlertSubjects.Kind.ALL_HOSTS, AlertSubjects.kind(0))
    }

    @Test
    fun onlyThePickedInterfacesAlertAndOneThatIsGoneCountsAsDown() {
        val snap = SnmpDevices.Snapshot(0L, "sw", "", interfaces = listOf(
            SnmpDevices.Interface(1, "uplink", adminUp = true, operUp = true),
            SnmpDevices.Interface(2, "spare", adminUp = true, operUp = false),
            SnmpDevices.Interface(3, "nas", adminUp = true, operUp = false),
            SnmpDevices.Interface(4, "off", adminUp = false, operUp = false),
        ))
        fun read(vararg names: String) = DeviceChecks.snmpReading(DeviceChecks.SNMP_INTERFACE_DOWN, DeviceChecks.encodePicked(names.toList()), snap)
        assertEquals("an unplugged spare port that was not picked says nothing", DeviceChecks.Reading(0f, emptyList()), read("uplink", "off"))
        assertEquals(DeviceChecks.Reading(1f, listOf("nas")), read("uplink", "nas"))
        assertEquals(DeviceChecks.Reading(2f, listOf("nas", "eth9 (not found)")), read("nas", "eth9"))
        assertTrue(DeviceChecks.breached(DeviceChecks.SNMP_INTERFACE_DOWN, 1f, 0f))
        assertFalse(DeviceChecks.breached(DeviceChecks.SNMP_INTERFACE_DOWN, 0f, 0f))
        assertEquals("Down: nas, eth9 (not found)", DeviceChecks.alertText(DeviceChecks.SNMP_INTERFACE_DOWN, 2f, 0f, listOf("nas", "eth9 (not found)")))
        assertEquals("Pick the interfaces to watch", DeviceChecks.problem(DeviceChecks.SNMP_INTERFACE_DOWN, "\n "))
        assertNull(DeviceChecks.problem(DeviceChecks.SNMP_INTERFACE_DOWN, "nas"))
    }

    @Test
    fun aUpsOnBatteryAndALowBatteryAlertAndADeviceWithoutAUpsSaysNothing() {
        fun snap(ups: SnmpDevices.Ups?) = SnmpDevices.Snapshot(0L, "ups", "", ups = ups)
        val mains = SnmpDevices.Ups("UPS-MIB", source = SnmpDevices.PowerSource.MAINS, battery = SnmpDevices.BatteryState.NORMAL, chargePercent = 100)
        val battery = mains.copy(source = SnmpDevices.PowerSource.BATTERY, chargePercent = 45, minutesLeft = 12)
        assertEquals(DeviceChecks.Reading(0f, emptyList()), DeviceChecks.snmpReading(DeviceChecks.SNMP_UPS_ON_BATTERY, "", snap(mains)))
        assertEquals(DeviceChecks.Reading(1f, listOf("12 min left", "45% charged")), DeviceChecks.snmpReading(DeviceChecks.SNMP_UPS_ON_BATTERY, "", snap(battery)))
        assertNull("not a UPS: unknown, so an incident stays as it is", DeviceChecks.snmpReading(DeviceChecks.SNMP_UPS_ON_BATTERY, "", snap(null)))
        assertNull("no source reported", DeviceChecks.snmpReading(DeviceChecks.SNMP_UPS_ON_BATTERY, "", snap(mains.copy(source = null))))

        val low = DeviceChecks.SNMP_UPS_BATTERY_LOW
        assertEquals(45f, DeviceChecks.snmpReading(low, "", snap(battery))?.value)
        assertFalse(DeviceChecks.breached(low, 45f, 30f))
        assertTrue(DeviceChecks.breached(low, 29f, 30f))
        val reportedLow = DeviceChecks.snmpReading(low, "", snap(battery.copy(battery = SnmpDevices.BatteryState.LOW)))
        assertEquals("the UPS's own word wins over its charge", DeviceChecks.BATTERY_REPORTED_LOW, reportedLow?.value)
        assertTrue(DeviceChecks.breached(low, reportedLow!!.value, 30f))
        assertNull("neither a charge nor a low battery reported", DeviceChecks.snmpReading(low, "", snap(mains.copy(chargePercent = null))))
        assertEquals("UPS battery at 25% (limit 30%)", DeviceChecks.alertText(low, 25f, 30f, listOf("25% charged")))
        assertEquals("The UPS reports a low battery: 45% charged", DeviceChecks.alertText(low, -1f, 30f, listOf("45% charged")))
        assertEquals("battery low", DeviceChecks.describe(low, -1f))
    }

    @Test
    fun aGuestsNewestFailedBackupAlertsUntilOneFinishesAndOnlyPickedGuestsMustRun() {
        fun guest(vmid: Int, name: String, status: String) = Proxmox.Guest("pve1", vmid, "qemu", name, status, null, null, null, null, null, false)
        fun task(id: String, start: Long, status: String) = Proxmox.Task("UPID:pve1:$id:$start", "pve1", "vzdump", id, "root@pam", start, start + 60, status)
        val guests = listOf(guest(100, "web", "running"), guest(101, "db", "stopped"), guest(102, "ci", "paused"))
        val failedThenFixed = Proxmox.Overview("8.4", emptyList(), guests, emptyList(), listOf(
            Proxmox.BackupRun(task("101", 300, "OK"), mapOf(101 to null)),
            Proxmox.BackupRun(task("", 200, "job errors"), mapOf(100 to "no space left on device", 101 to "no space left on device")),
            Proxmox.BackupRun(task("102", 100, "ERROR: storage offline"), mapOf(102 to "ERROR: storage offline")),
        ))
        val failed = DeviceChecks.PROXMOX_BACKUP_FAILED
        val reading = DeviceChecks.proxmoxReading(failed, "", failedThenFixed)
        assertEquals("101 backed up since; 100 and 102 not", DeviceChecks.Reading(2f, listOf("VM 100 (web): no space left on device", "VM 102 (ci): ERROR: storage offline")), reading)
        assertTrue(DeviceChecks.breached(failed, reading!!.value, 0f))
        assertEquals("Backup failed: VM 100 (web): no space left on device, VM 102 (ci): ERROR: storage offline", DeviceChecks.alertText(failed, 2f, 0f, reading.names))
        assertEquals("backups OK", DeviceChecks.summary(failed, 0f, emptyList()))
        assertEquals("a failure alerts at once", "0m", DeviceChecks.defaultWindow(failed))

        val stopped = DeviceChecks.PROXMOX_GUEST_STOPPED
        assertEquals("Pick the guests that should be running", DeviceChecks.problem(stopped, ""))
        val picked = DeviceChecks.encodePicked(listOf("100", "101", "102", "999"))
        assertEquals(
            DeviceChecks.Reading(3f, listOf("VM 101 (db): stopped", "VM 102 (ci): paused", "VM 999 (not found)")),
            DeviceChecks.proxmoxReading(stopped, picked, failedThenFixed),
        )
        assertEquals(DeviceChecks.Reading(0f, emptyList()), DeviceChecks.proxmoxReading(stopped, "100", failedThenFixed))
        assertEquals("1 guest not running: VM 101 (db): stopped", DeviceChecks.summary(stopped, 1f, listOf("VM 101 (db): stopped")))
        assertTrue(DeviceChecks.isYesNo(stopped) && DeviceChecks.picksItems(stopped) && DeviceChecks.isProxmox(stopped))
        assertFalse(DeviceChecks.isSnmp(stopped))
    }
}
