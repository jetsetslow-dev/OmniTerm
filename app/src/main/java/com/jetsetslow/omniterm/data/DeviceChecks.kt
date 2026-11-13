package com.jetsetslow.omniterm.data

/**
 * Who an alert rule or incident is about, kept in its `serverId`: a host (its id), every host (0),
 * or a device the phone reads itself without SSH, encoded below 0 so no host query ever matches it:
 * an SNMP device as -2·id, a Proxmox VE server as -(2·id + 1).
 */
object AlertSubjects {
    enum class Kind { HOST, ALL_HOSTS, SNMP, PROXMOX }

    fun snmp(deviceId: Int) = -(2 * deviceId)
    fun proxmox(serverId: Int) = -(2 * serverId + 1)

    fun kind(subject: Int): Kind = when {
        subject > 0 -> Kind.HOST
        subject == 0 -> Kind.ALL_HOSTS
        (-subject) % 2 == 0 -> Kind.SNMP
        else -> Kind.PROXMOX
    }

    /** The device's own id, for an SNMP or Proxmox subject. */
    fun deviceId(subject: Int): Int = -subject / 2

    fun isDevice(subject: Int) = subject < 0
}

/**
 * Alert rules about a device the phone reads itself, with no SSH host between: an SNMP device's
 * picked interfaces and its UPS. They are checked on the same pace and through the same incidents,
 * notifications and forwarding as host checks, and only read: nothing here changes a device.
 *
 * Credit: the interface and UPS alerts follow LibreNMS's alert rule collection (a port down, a UPS
 * on battery or with a low battery).
 */
object DeviceChecks {
    const val SNMP_INTERFACE_DOWN = "SNMP Interface Down"
    const val SNMP_UPS_ON_BATTERY = "SNMP UPS On Battery"
    const val SNMP_UPS_BATTERY_LOW = "SNMP UPS Battery Low"

    val SNMP = listOf(SNMP_INTERFACE_DOWN, SNMP_UPS_ON_BATTERY, SNMP_UPS_BATTERY_LOW)
    val ALL = SNMP

    /** A battery the UPS itself calls low or depleted, whatever its charge: reads below 0 and alerts. */
    const val BATTERY_REPORTED_LOW = -1f
    const val DEFAULT_CHARGE_PERCENT = 30f

    fun isDeviceCheck(metricName: String) = metricName in ALL
    fun isSnmp(metricName: String) = metricName in SNMP

    /** Checks that alert on yes or no (any item down or stopped); only Battery Low takes a threshold. */
    fun isYesNo(metricName: String) = isDeviceCheck(metricName) && metricName != SNMP_UPS_BATTERY_LOW

    /** Checks whose rule names the items to watch (interfaces), kept one per line in its target. */
    fun picksItems(metricName: String) = metricName == SNMP_INTERFACE_DOWN

    fun defaultThreshold(metricName: String): Float = if (metricName == SNMP_UPS_BATTERY_LOW) DEFAULT_CHARGE_PERCENT else 0f

    /** A link or the mains gets two minutes to come back. */
    @Suppress("UNUSED_PARAMETER")
    fun defaultWindow(metricName: String): String = "2m"

    /** Devices are read once a minute for their rules, and never more often than hosts are polled. */
    const val MIN_INTERVAL_MS = 60_000L

    /** The items a rule watches, from its target. */
    fun picked(target: String): List<String> = target.split('\n').map { it.trim() }.filter { it.isNotEmpty() }.distinct()

    fun encodePicked(items: Collection<String>): String = items.map { it.replace('\n', ' ').trim() }.filter { it.isNotEmpty() }.distinct().joinToString("\n")

    /** Why a rule cannot be saved as it is, or null. */
    fun problem(metricName: String, target: String): String? = when {
        metricName == SNMP_INTERFACE_DOWN && picked(target).isEmpty() -> "Pick the interfaces to watch"
        else -> null
    }

    /** Battery Low alerts below its limit, which a battery the UPS calls low (-1) always is. */
    fun breached(metricName: String, value: Float, threshold: Float): Boolean =
        if (metricName == SNMP_UPS_BATTERY_LOW) value < threshold else value > 0f

    /** One reading: the value, and the items behind it for the alert's text. */
    data class Reading(val value: Float, val names: List<String>)

    /**
     * What an SNMP rule reads from [snapshot], or null when the device does not report it (no UPS,
     * say), which leaves any incident as it is. An interface that is no longer listed counts as down.
     */
    fun snmpReading(metricName: String, target: String, snapshot: SnmpDevices.Snapshot): Reading? = when (metricName) {
        SNMP_INTERFACE_DOWN -> {
            val byName = snapshot.interfaces.associateBy { it.name }
            val down = picked(target).mapNotNull { name ->
                val i = byName[name]
                when {
                    i == null -> "$name (not found)"
                    i.down -> name
                    else -> null
                }
            }
            Reading(down.size.toFloat(), down)
        }
        SNMP_UPS_ON_BATTERY -> snapshot.ups?.let { ups ->
            ups.source?.let {
                if (ups.onBattery) Reading(1f, listOfNotNull(ups.minutesLeft?.let { m -> "$m min left" }, ups.chargePercent?.let { c -> "$c% charged" }))
                else Reading(0f, emptyList())
            }
        }
        SNMP_UPS_BATTERY_LOW -> snapshot.ups?.let { ups ->
            val charge = ups.chargePercent
            val names = listOfNotNull(charge?.let { "$it% charged" }, ups.minutesLeft?.let { "$it min left" })
            when {
                ups.batteryLow -> Reading(BATTERY_REPORTED_LOW, names)
                charge != null -> Reading(charge.toFloat(), names)
                else -> null
            }
        }
        else -> null
    }

    fun describe(metricName: String, value: Float): String = when (metricName) {
        SNMP_INTERFACE_DOWN -> plural(value.toInt(), "interface down", "interfaces down")
        SNMP_UPS_ON_BATTERY -> if (value > 0f) "on battery" else "on mains"
        SNMP_UPS_BATTERY_LOW -> if (value < 0f) "battery low" else "${value.toInt()}% charged"
        else -> value.toString()
    }

    /** The last reading as the rule list shows it, naming up to three items. */
    fun summary(metricName: String, value: Float, names: List<String>): String {
        val listed = names.take(3).joinToString(", ") + if (names.size > 3) " and ${names.size - 3} more" else ""
        return describe(metricName, value) + if (listed.isNotEmpty()) ": $listed" else ""
    }

    /**
     * The notification line, naming up to five items. Posted again later (after a mute) without the
     * names, it says what was seen.
     */
    fun alertText(metricName: String, value: Float, threshold: Float, names: List<String>): String {
        val listed = names.take(5).joinToString(", ") + if (names.size > 5) " and ${names.size - 5} more" else ""
        val with = if (listed.isNotEmpty()) ": $listed" else ""
        return when (metricName) {
            SNMP_INTERFACE_DOWN -> if (listed.isEmpty()) describe(metricName, value) else "Down$with"
            SNMP_UPS_ON_BATTERY -> "UPS on battery$with"
            SNMP_UPS_BATTERY_LOW -> if (value < 0f) "The UPS reports a low battery$with" else "UPS battery at ${value.toInt()}% (limit ${threshold.toInt()}%)"
            else -> describe(metricName, value)
        }
    }

    private fun plural(n: Int, one: String, many: String = one + "s") = "$n ${if (n == 1) one else many}"
}
