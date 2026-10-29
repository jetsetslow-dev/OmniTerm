package com.jetsetslow.omniterm.data

/** The sections of a host's system specs, in the order they are shown. */
enum class SpecKind { System, Cpu, Memory, Storage, Gpu, Network }

/**
 * Why part of a section is missing, so the screen can say so and offer what would fix it: a
 * [tool] the host lacks can be installed from the notice.
 */
enum class SpecNotice(val tool: HostTool? = null) {
    /** Memory modules come from the firmware tables, which only root can read. */
    ModulesNeedRoot,

    /** Root could read them, but dmidecode is not installed. */
    ModulesToolMissing(HostTool.Dmidecode),

    /** dmidecode ran and the firmware lists no modules (most virtual machines). */
    NoModulesReported,

    /** Drive health and wear come from SMART, which only root can read. */
    DriveHealthNeedsRoot,

    /** Root could read it, but smartctl is not installed. */
    DriveHealthToolMissing(HostTool.Smartmontools),

    /** NVIDIA's driver is loaded, but nvidia-smi, which reports the card's memory and more, is not installed. */
    GpuToolMissing(HostTool.NvidiaSmi),
}

/** One labelled value, e.g. "L2 cache" → "1.5 MiB (6 instances)". An empty label shows the value alone. */
data class SpecField(val label: String, val value: String)

/** One device inside a section: a memory module, a drive, a graphics card, a network adapter. */
data class SpecItem(val title: String, val summary: String = "", val fields: List<SpecField> = emptyList())

/** A collapsible section: its own fields, then its devices, then why anything is missing. */
data class SpecSection(
    val kind: SpecKind,
    val summary: String = "",
    val fields: List<SpecField> = emptyList(),
    val items: List<SpecItem> = emptyList(),
    val notices: List<SpecNotice> = emptyList(),
)

/** Everything the specs probe learned about one host. */
data class SystemSpecs(
    val sections: List<SpecSection>,
    /** Seconds since boot, when the host reports it; the screen formats it. */
    val uptimeSeconds: Long? = null,
    /** sudo's own explanation when an elevated read was refused. */
    val sudoError: String? = null,
) {
    fun section(kind: SpecKind): SpecSection? = sections.find { it.kind == kind }

    /** True when reading again with sudo would fill in something that is missing now. */
    val wouldGainFromSudo: Boolean
        get() = sections.any { s -> s.notices.any { it == SpecNotice.ModulesNeedRoot || it == SpecNotice.DriveHealthNeedsRoot } }

    /** Plain text for the clipboard, section by section, with [titles] naming each section. */
    fun asText(titles: (SpecKind) -> String): String = buildString {
        sections.forEach { section ->
            if (isNotEmpty()) append('\n')
            append(titles(section.kind))
            if (section.summary.isNotEmpty()) append(" — ").append(section.summary)
            append('\n')
            section.fields.forEach { appendField(it, "  ") }
            section.items.forEach { item ->
                append("  ").append(item.title)
                if (item.summary.isNotEmpty()) append(" — ").append(item.summary)
                append('\n')
                item.fields.forEach { appendField(it, "    ") }
            }
        }
    }

    private fun StringBuilder.appendField(field: SpecField, indent: String) {
        append(indent)
        if (field.label.isNotEmpty()) append(field.label).append(": ")
        append(field.value).append('\n')
    }
}

/**
 * The command that reads a host's specs, one per operating system family (see
 * [RemoteCommands.normaliseOs]). Each prints `@SECTION` blocks for [SystemSpecsParser].
 *
 * Memory modules and drive health need root on Linux and the BSDs. As root they are read
 * straight away; otherwise only when the user asks to read with sudo, so opening the screen never
 * tries sudo behind the user's back (a failed sudo is logged, and can mail the administrator).
 * macOS reports both without root, and Windows reports what the signed-in account may see.
 */
object SystemSpecsCommands {

    fun forOs(os: String, sudoPassword: String? = null): String = when (RemoteCommands.normaliseOs(os)) {
        "Windows" -> WINDOWS
        "Darwin" -> DARWIN
        "FreeBSD" -> bsd(sudoPassword)
        else -> linux(sudoPassword)
    }

    /** `printf key<TAB>value` for each sysctl that answers; unknown keys are skipped quietly. */
    private fun sysctlFields(keys: List<String>): String =
        "for k in ${keys.joinToString(" ")}; do v=\$(sysctl -n \$k 2>/dev/null) && [ -n \"\$v\" ] && " +
            "printf '%s\\t%s\\n' \$k \"\$v\"; done; "

    /**
     * Runs [privileged] as root: directly when already root, through sudo when [sudoPassword] is
     * given (blank tries passwordless sudo), and not at all otherwise. It comes first so that a
     * password on stdin reaches sudo before any other command could read it.
     */
    private fun elevated(privileged: String, sudoPassword: String?): String = when (sudoPassword) {
        null -> "if [ \"\$(id -u)\" = 0 ]; then sh -c ${RemoteCommands.shellQuote(privileged)}; fi; "
        else -> "if [ \"\$(id -u)\" = 0 ]; then sh -c ${RemoteCommands.shellQuote(privileged)}; else " +
            RemoteCommands.sudoShWrap(privileged, sudoPassword) + "; fi; "
    }

    /** Root-only reads: memory modules from dmidecode, then SMART for each drive in [drives]. */
    private fun privileged(drives: String): String =
        RemoteCommands.OT_HELPER + "echo '@PRIV'; " +
            "echo '@DIMM'; if command -v dmidecode >/dev/null 2>&1; then ot 10 dmidecode -t 16,17 2>&1; else echo '$MISSING'; fi; " +
            "echo '@SMART'; if command -v smartctl >/dev/null 2>&1; then for d in $drives; do " +
            "echo \"$DEVICE_MARKER\$d\"; ot 10 smartctl -i -H -A /dev/\$d 2>&1; done; else echo '$MISSING'; fi; true"

    const val MISSING = "!MISSING"
    const val DEVICE_MARKER = "##DEV "

    private val LINUX_DRIVES =
        "\$(ls /sys/block 2>/dev/null | grep -vE '^(loop|ram|zram|sr|fd|dm-|md|nbd)')"

    private fun linux(sudoPassword: String?): String = buildString {
        append(elevated(privileged(LINUX_DRIVES), sudoPassword))
        append(RemoteCommands.OT_HELPER)
        append("echo '@OS'; uname -srm 2>/dev/null; ")
        append("echo '@HOSTNAME'; hostname 2>/dev/null || cat /proc/sys/kernel/hostname 2>/dev/null; ")
        append("echo '@RELEASE'; cat /etc/os-release 2>/dev/null; ")
        append("echo '@UPTIME'; cat /proc/uptime 2>/dev/null; ")
        append("echo '@VIRT'; systemd-detect-virt 2>/dev/null; ")
        // Readable without root, except the serial numbers, which are left out.
        append("echo '@DMI'; for f in sys_vendor product_name product_version product_family board_vendor board_name ")
        append("board_version bios_vendor bios_version bios_date chassis_type; do [ -r /sys/class/dmi/id/\$f ] && ")
        append("printf '%s\\t%s\\n' \$f \"\$(cat /sys/class/dmi/id/\$f 2>/dev/null)\"; done; ")
        // Boards without DMI (Raspberry Pi and other ARM boards) name themselves in the device tree.
        append("echo '@MODEL'; [ -r /proc/device-tree/model ] && tr -d '\\000' < /proc/device-tree/model; echo; ")
        append("echo '@LSCPU'; LANG=C lscpu 2>/dev/null; ")
        // The first processor's block, plus the board lines ARM prints once at the end.
        append("echo '@CPUINFO'; sed '/^\$/q' /proc/cpuinfo 2>/dev/null; ")
        append("grep -E '^(Hardware|Revision|Model)[[:space:]]*:' /proc/cpuinfo 2>/dev/null | sort -u; ")
        append("echo '@CPUFREQ'; c=/sys/devices/system/cpu/cpu0/cpufreq; ")
        append("for f in scaling_driver scaling_governor cpuinfo_min_freq cpuinfo_max_freq; do ")
        append("[ -r \$c/\$f ] && printf '%s\\t%s\\n' \$f \"\$(cat \$c/\$f)\"; done; ")
        append("printf 'scaling_cur_freq\\t%s\\n' \"\$(cat /sys/devices/system/cpu/cpu[0-9]*/cpufreq/scaling_cur_freq 2>/dev/null | tr '\\n' ' ')\"; ")
        append("echo '@VULN'; grep -H . /sys/devices/system/cpu/vulnerabilities/* 2>/dev/null; ")
        append("echo '@MEMINFO'; cat /proc/meminfo 2>/dev/null; ")
        append("echo '@SWAPS'; tail -n +2 /proc/swaps 2>/dev/null; ")
        // lsblk's key="value" pairs; older lsblk lacks some columns, and BusyBox has no lsblk, so
        // /sys/block stands in with the same pairs.
        append("echo '@BLOCK'; lsblk -b -P -o NAME,PKNAME,TYPE,SIZE,MODEL,SERIAL,VENDOR,REV,TRAN,ROTA,RM,FSTYPE,LABEL,MOUNTPOINT,PHY-SEC,LOG-SEC 2>/dev/null || ")
        append("lsblk -b -P -o NAME,TYPE,SIZE,MODEL,ROTA,RM,FSTYPE,MOUNTPOINT 2>/dev/null || ")
        append("for b in /sys/block/*; do n=\${b##*/}; printf 'NAME=\"%s\" TYPE=\"disk\" SIZE=\"%s\" MODEL=\"%s\" ROTA=\"%s\" RM=\"%s\"\\n' ")
        append("\$n \"\$((\$(cat \$b/size 2>/dev/null || echo 0) * 512))\" \"\$(cat \$b/device/model 2>/dev/null)\" ")
        append("\"\$(cat \$b/queue/rotational 2>/dev/null)\" \"\$(cat \$b/removable 2>/dev/null)\"; done; ")
        append("echo '@DF'; ot 5 df -PB1 2>/dev/null || ot 5 df -Pk 2>/dev/null | sed 's/^/KB1024 /'; ")
        // Graphics: each DRM card's PCI ids, driver, video memory (AMD) and slot; lspci names them.
        append("echo '@DRM'; for c in /sys/class/drm/card[0-9]*; do case \${c##*/} in *-*) continue;; esac; d=\$c/device; ")
        append("printf '%s\\t%s\\t%s\\t%s\\t%s\\t%s\\n' \${c##*/} \"\$(cat \$d/vendor 2>/dev/null)\" \"\$(cat \$d/device 2>/dev/null)\" ")
        append("\"\$(basename \"\$(readlink \$d/driver 2>/dev/null)\" 2>/dev/null)\" \"\$(cat \$d/mem_info_vram_total 2>/dev/null)\" ")
        append("\"\$(basename \"\$(readlink -f \$d 2>/dev/null)\" 2>/dev/null)\"; done; ")
        append("echo '@LSPCI'; lspci -mm 2>/dev/null | grep -iE '\"(VGA|3D|Display|Ethernet|Network)'; ")
        append("echo '@NVIDIA'; if command -v nvidia-smi >/dev/null 2>&1; then ot 10 nvidia-smi --query-gpu=pci.bus_id,name,driver_version,")
        append("memory.total,vbios_version,pcie.link.gen.max,pcie.link.width.max,power.limit,temperature.gpu --format=csv,noheader 2>/dev/null; ")
        append("elif [ -e /proc/driver/nvidia/version ] && [ -e /dev/nvidiactl ]; then echo '$MISSING'; fi; ")
        // Physical interfaces only (those backed by a device); bridges, veths and tunnels are not hardware.
        append("echo '@NET'; for i in /sys/class/net/*; do [ -e \$i/device ] || continue; ")
        append("printf '%s\\t%s\\t%s\\t%s\\t%s\\t%s\\t%s\\t%s\\n' \${i##*/} \"\$(cat \$i/address 2>/dev/null)\" \"\$(cat \$i/operstate 2>/dev/null)\" ")
        append("\"\$(cat \$i/speed 2>/dev/null)\" \"\$(cat \$i/mtu 2>/dev/null)\" \"\$(basename \"\$(readlink \$i/device/driver 2>/dev/null)\" 2>/dev/null)\" ")
        append("\"\$(basename \"\$(readlink -f \$i/device 2>/dev/null)\" 2>/dev/null)\" \"\$([ -d \$i/wireless ] && echo wireless)\"; done; ")
        append("echo '@ADDR'; ip -o addr show 2>/dev/null; true")
    }

    private val BSD_SYSCTLS = listOf(
        "hw.model", "hw.machine", "hw.machine_arch", "hw.ncpu", "kern.smp.cpus", "kern.smp.cores",
        "kern.smp.threads_per_core", "hw.clockrate", "hw.cpuspeed", "dev.cpu.0.freq", "dev.cpu.0.freq_levels",
        "hw.physmem", "hw.realmem", "hw.usermem", "hw.pagesize", "kern.boottime", "kern.vm_guest",
        "hw.vendor", "hw.product", "hw.version", "kern.disks", "hw.disknames",
    )

    private fun bsd(sudoPassword: String?): String = buildString {
        append(elevated(privileged("\$(sysctl -n kern.disks 2>/dev/null | tr ' ' '\\n' | grep -vE '^(cd|md)')"), sudoPassword))
        append("echo '@OS'; uname -srm 2>/dev/null; ")
        append("echo '@HOSTNAME'; hostname 2>/dev/null; ")
        append("echo '@RELEASE'; freebsd-version 2>/dev/null; ")
        append("echo '@NOW'; date +%s; ")
        append("echo '@SYSCTL'; ").append(sysctlFields(BSD_SYSCTLS))
        // FreeBSD keeps the SMBIOS identity in the kernel environment rather than in sysctl.
        append("for k in smbios.system.maker smbios.system.product smbios.system.version smbios.planar.maker ")
        append("smbios.planar.product smbios.bios.vendor smbios.bios.version smbios.bios.reldate smbios.chassis.type; do ")
        append("v=\$(kenv -q \$k 2>/dev/null) && [ -n \"\$v\" ] && printf '%s\\t%s\\n' \$k \"\$v\"; done; ")
        append("echo '@DMESG'; grep -E '^(CPU:|  Origin|  Features|  AMD Features|  Structured Extended|  AMD Extended)' /var/run/dmesg.boot 2>/dev/null; ")
        append("echo '@SWAP'; { swapinfo -k 2>/dev/null || swapctl -lk 2>/dev/null; } | tail -n +2; ")
        append("echo '@GEOM'; geom disk list 2>/dev/null; ")
        append("echo '@DF'; df -Pk 2>/dev/null; ")
        append("echo '@MOUNT'; mount -p 2>/dev/null || mount 2>/dev/null; ")
        append("echo '@PCI'; pciconf -lv 2>/dev/null; ")
        append("echo '@IFCONFIG'; ifconfig -a 2>/dev/null; true")
    }

    private val DARWIN_SYSCTLS = listOf(
        "machdep.cpu.brand_string", "machdep.cpu.vendor", "machdep.cpu.family", "machdep.cpu.model",
        "machdep.cpu.stepping", "machdep.cpu.microcode_version", "hw.physicalcpu", "hw.logicalcpu",
        "hw.perflevel0.name", "hw.perflevel0.physicalcpu", "hw.perflevel1.name", "hw.perflevel1.physicalcpu",
        "hw.cpufrequency", "hw.cpufrequency_max", "hw.l1icachesize", "hw.l1dcachesize", "hw.l2cachesize",
        "hw.l3cachesize", "hw.memsize", "hw.pagesize", "vm.swapusage", "kern.boottime", "kern.hv_vmm_present",
        "machdep.cpu.features", "machdep.cpu.leaf7_features", "machdep.cpu.extfeatures",
    )

    // system_profiler names the memory modules and drives (with SMART status) without root.
    private val DARWIN = buildString {
        append("echo '@OS'; uname -srm 2>/dev/null; ")
        append("echo '@HOSTNAME'; hostname 2>/dev/null; ")
        append("echo '@SWVERS'; sw_vers 2>/dev/null; ")
        append("echo '@NOW'; date +%s; ")
        append("echo '@SYSCTL'; ").append(sysctlFields(DARWIN_SYSCTLS))
        append("echo '@PROFILER'; system_profiler SPHardwareDataType SPMemoryDataType SPStorageDataType SPDisplaysDataType 2>/dev/null; ")
        // -P drops macOS's inode columns, which would otherwise end up in the mount point.
        append("echo '@DF'; df -Pk 2>/dev/null; ")
        append("echo '@HWPORTS'; networksetup -listallhardwareports 2>/dev/null; ")
        append("echo '@IFCONFIG'; ifconfig -a 2>/dev/null; true")
    }

    // One record per object: `##ITEM` and then `Property=value` lines. Single quotes only, so
    // the double-quoted -Command survives cmd.exe, OpenSSH's default shell on Windows.
    private val WINDOWS =
        "powershell -NoProfile -Command \"\$ErrorActionPreference='SilentlyContinue'; " +
            "function E(\$n,\$o,\$p){ Write-Output ('@'+\$n); foreach(\$x in @(\$o)){ if(\$x -eq \$null){continue}; " +
            "Write-Output '##ITEM'; foreach(\$k in \$p){ \$v=\$x.\$k; if(\$v -ne \$null -and [string]\$v -ne ''){ " +
            "Write-Output (\$k+'='+(@(\$v) -join ', ')) } } } }; " +
            "E 'OS' (Get-CimInstance Win32_OperatingSystem) 'Caption','Version','BuildNumber','OSArchitecture','InstallDate'," +
            "'LastBootUpTime','CSName','FreePhysicalMemory'; " +
            "E 'CS' (Get-CimInstance Win32_ComputerSystem) 'Manufacturer','Model','SystemFamily','SystemType'," +
            "'NumberOfProcessors','NumberOfLogicalProcessors','TotalPhysicalMemory','HypervisorPresent','Domain'; " +
            "E 'BIOS' (Get-CimInstance Win32_BIOS) 'Manufacturer','SMBIOSBIOSVersion','ReleaseDate'; " +
            "E 'BOARD' (Get-CimInstance Win32_BaseBoard) 'Manufacturer','Product','Version'; " +
            "E 'CPU' (Get-CimInstance Win32_Processor) 'Name','Manufacturer','Description','SocketDesignation'," +
            "'NumberOfCores','NumberOfLogicalProcessors','MaxClockSpeed','CurrentClockSpeed','L2CacheSize','L3CacheSize'," +
            "'AddressWidth','VirtualizationFirmwareEnabled','SecondLevelAddressTranslationExtensions'; " +
            "E 'MEMARRAY' (Get-CimInstance Win32_PhysicalMemoryArray) 'MemoryDevices','MaxCapacityEx'; " +
            "E 'DIMM' (Get-CimInstance Win32_PhysicalMemory) 'DeviceLocator','BankLabel','Capacity','SMBIOSMemoryType'," +
            "'FormFactor','Speed','ConfiguredClockSpeed','ConfiguredVoltage','Manufacturer','PartNumber'; " +
            "E 'PAGEFILE' (Get-CimInstance Win32_PageFileUsage) 'Name','AllocatedBaseSize','CurrentUsage','PeakUsage'; " +
            "E 'PDISK' (Get-PhysicalDisk) 'DeviceId','FriendlyName','MediaType','BusType','Size','HealthStatus'," +
            "'OperationalStatus','FirmwareVersion','SpindleSpeed'; " +
            "E 'DISKDRIVE' (Get-CimInstance Win32_DiskDrive) 'Index','Model','Size','InterfaceType','MediaType','FirmwareRevision','Partitions'; " +
            "E 'RELIABILITY' (Get-PhysicalDisk | Get-StorageReliabilityCounter) 'DeviceId','Temperature','Wear','PowerOnHours'," +
            "'ReadErrorsTotal','WriteErrorsTotal'; " +
            "E 'VOLUME' (Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3') 'DeviceID','VolumeName','FileSystem','Size','FreeSpace'; " +
            "E 'GPU' (Get-CimInstance Win32_VideoController) 'Name','AdapterCompatibility','DriverVersion','DriverDate','AdapterRAM'," +
            "'VideoProcessor','CurrentHorizontalResolution','CurrentVerticalResolution','CurrentRefreshRate'; " +
            "E 'NIC' (Get-CimInstance Win32_NetworkAdapter -Filter 'PhysicalAdapter=True') 'Index','Name','NetConnectionID'," +
            "'MACAddress','Speed','NetConnectionStatus','Manufacturer'; " +
            "E 'NICCONF' (Get-CimInstance Win32_NetworkAdapterConfiguration -Filter 'IPEnabled=True') 'Index','IPAddress'," +
            "'DefaultIPGateway','DNSServerSearchOrder','DHCPEnabled'\""
}

/** Turns [SystemSpecsCommands] output into [SystemSpecs]. */
object SystemSpecsParser {

    fun parse(os: String, output: String): SystemSpecs {
        val sections = RemoteParsers.splitSections(output)
        val specs = when (RemoteCommands.normaliseOs(os)) {
            "Windows" -> windows(sections)
            "Darwin" -> darwin(sections)
            "FreeBSD" -> bsd(sections)
            else -> linux(sections)
        }
        // Whatever sudo said before the first section is its refusal; the privileged part never ran.
        val sudoError = if ("PRIV" !in sections) {
            output.lineSequence().takeWhile { !it.startsWith("@") }
                .map { it.trim() }.lastOrNull { it.isNotEmpty() }
        } else {
            null
        }
        return specs.copy(sections = specs.sections.filter { it.fields.isNotEmpty() || it.items.isNotEmpty() || it.notices.isNotEmpty() }, sudoError = sudoError)
    }

    // ── shared helpers ──────────────────────────────────────────────────────────────────────

    private fun field(label: String, value: String?): SpecField? =
        value?.trim()?.takeIf { it.isNotEmpty() }?.let { SpecField(label, it) }

    /** Firmware fills unset identity strings with these; showing them would look like data. */
    private val PLACEHOLDERS = setOf(
        "to be filled by o.e.m.", "default string", "not specified", "not provided", "system product name",
        "system manufacturer", "system version", "o.e.m.", "none", "unknown", "not applicable", "n/a", "na", "0x00000000",
    )

    private fun real(value: String?): String? = value?.trim()?.takeIf { it.isNotEmpty() && it.lowercase() !in PLACEHOLDERS }

    /** The present, real parts joined by [separator]. */
    private fun joined(vararg parts: String?, separator: String = " "): String? =
        parts.mapNotNull { real(it) }.distinct().joinToString(separator).takeIf { it.isNotEmpty() }

    private fun dotted(vararg parts: String?): String = parts.mapNotNull { real(it) }.joinToString(" · ")

    /** "key: value" lines (the first [separator] splits), ignoring lines without one. */
    private fun keyValues(text: String?, separator: Char = ':'): List<Pair<String, String>> =
        text.orEmpty().lineSequence().mapNotNull { line ->
            val at = line.indexOf(separator)
            if (at <= 0) null else line.substring(0, at).trim() to line.substring(at + 1).trim()
        }.filter { it.first.isNotEmpty() }.toList()

    private fun tabValues(text: String?): Map<String, String> =
        text.orEmpty().lineSequence().mapNotNull { line ->
            val at = line.indexOf('\t')
            if (at <= 0) null else line.substring(0, at).trim() to line.substring(at + 1).trim()
        }.toMap()

    private fun bytes(value: Long?): String? = value?.takeIf { it > 0 }?.let { RemoteParsers.humanBytes(it) }

    private fun count(n: Int, one: String, many: String) = if (n == 1) "1 $one" else "$n $many"

    private fun megahertz(mhz: Long?): String? = mhz?.takeIf { it > 0 }?.let {
        if (it >= 1000) String.format(java.util.Locale.US, "%.2f GHz", it / 1000.0) else "$it MHz"
    }

    /** Link speed in Mb/s as people say it: "1 Gb/s", "2.5 Gb/s", "100 Mb/s". */
    private fun linkSpeed(mbps: Long?): String? = mbps?.takeIf { it > 0 }?.let {
        if (it >= 1000) {
            val gbps = it / 1000.0
            (if (gbps % 1.0 == 0.0) gbps.toLong().toString() else gbps.toString()) + " Gb/s"
        } else {
            "$it Mb/s"
        }
    }

    private fun usage(disk: DiskUsage): String =
        "${RemoteParsers.humanBytes(disk.usedBytes)} used of ${RemoteParsers.humanBytes(disk.totalBytes)} (${disk.percent.toInt()}%)"

    private val PCI_VENDORS = mapOf(
        "0x10de" to "NVIDIA", "0x1002" to "AMD", "0x8086" to "Intel", "0x1a03" to "ASPEED", "0x15ad" to "VMware",
        "0x1234" to "QEMU", "0x1af4" to "Red Hat (virtio)", "0x14e4" to "Broadcom", "0x10ec" to "Realtek",
        "0x106b" to "Apple", "0x1414" to "Microsoft", "0x80ee" to "VirtualBox",
    )

    private val CHASSIS = mapOf(
        3 to "Desktop", 4 to "Low-profile desktop", 5 to "Pizza box", 6 to "Mini tower", 7 to "Tower", 8 to "Portable",
        9 to "Laptop", 10 to "Notebook", 11 to "Handheld", 13 to "All-in-one", 14 to "Sub-notebook", 17 to "Server chassis",
        23 to "Rack-mount", 24 to "Sealed-case PC", 30 to "Tablet", 31 to "Convertible", 32 to "Detachable",
        34 to "Embedded PC", 35 to "Mini PC", 36 to "Stick PC",
    )

    /**
     * dmidecode's memory array (type 16) and memory devices (type 17): the array gives the slot
     * count and maximum, each device one module or an empty slot. Shared by Linux and the BSDs.
     */
    internal fun dmidecodeMemory(text: String?): Pair<List<SpecField>, List<SpecItem>> {
        val arrayFields = mutableListOf<SpecField>()
        val modules = mutableListOf<SpecItem>()
        text.orEmpty().split(Regex("\\n\\s*\\n")).forEach { block ->
            val lines = block.lines()
            val kind = lines.map { it.trim() }
            val values = lines.filter { it.startsWith("\t") && !it.startsWith("\t\t") }
                .mapNotNull { line -> line.indexOf(':').takeIf { it > 0 }?.let { line.substring(0, it).trim() to line.substring(it + 1).trim() } }
                .filter { (k, v) -> v.isNotEmpty() && !k.endsWith("Handle") }
            val map = values.toMap()
            when {
                "Physical Memory Array" in kind -> values.forEach { (k, v) ->
                    if (k in setOf("Location", "Use", "Error Correction Type", "Maximum Capacity", "Number Of Devices")) arrayFields += SpecField(k, v)
                }
                "Memory Device" in kind -> {
                    val size = map["Size"]
                    val empty = size == null || size.startsWith("No Module", true) || size == "0" || size.startsWith("Not Installed", true)
                    val title = joined(map["Locator"], map["Bank Locator"], separator = " · ") ?: "Module ${modules.size + 1}"
                    modules += if (empty) {
                        SpecItem(title, "Empty")
                    } else {
                        SpecItem(
                            title,
                            dotted(size, map["Type"], map["Configured Memory Speed"] ?: map["Speed"], map["Manufacturer"]),
                            values.filter { (_, v) -> real(v) != null }.map { (k, v) -> SpecField(k, v) },
                        )
                    }
                }
            }
        }
        return arrayFields to modules
    }

    /** One drive's `smartctl -i -H -A`: identity, the overall verdict, and each attribute's raw value. */
    internal fun smartctl(text: String?): Map<String, List<SpecField>> {
        val byDevice = LinkedHashMap<String, List<SpecField>>()
        text.orEmpty().split(SystemSpecsCommands.DEVICE_MARKER).drop(1).forEach { chunk ->
            val device = chunk.lineSequence().first().trim()
            val fields = mutableListOf<SpecField>()
            var health: String? = null
            val attribute = Regex("^\\s*\\d+\\s+(\\S+)\\s+0x[0-9a-fA-F]+\\s+\\d+\\s+\\d+\\s+\\S+\\s+\\S+\\s+\\S+\\s+(\\S+)\\s+(.+)$")
            chunk.lineSequence().drop(1).forEach { line ->
                val row = attribute.find(line)
                when {
                    line.contains("overall-health") || line.contains("Health Status:") ->
                        health = line.substringAfterLast(':').trim()
                    row != null -> {
                        val (name, whenFailed, raw) = row.destructured
                        val failing = if (whenFailed != "-") " (failing: $whenFailed)" else ""
                        fields += SpecField(name.replace('_', ' '), raw.trim() + failing)
                    }
                    else -> {
                        val at = line.indexOf(':')
                        if (at > 0 && line.first().isLetter()) {
                            val key = line.substring(0, at).trim()
                            val value = line.substring(at + 1).trim()
                            if (value.isNotEmpty() && SMART_SKIP.none { key.startsWith(it) }) fields += SpecField(key, value)
                        }
                    }
                }
            }
            if (health != null || fields.isNotEmpty()) {
                byDevice[device] = listOfNotNull(health?.let { SpecField("SMART health", it) }) + fields
            }
        }
        return byDevice
    }

    private val SMART_SKIP = listOf("Local Time is", "SMART support is", "smartctl", "Copyright", "Device is", "Read SMART", "SMART Status")

    /** A drive's smartctl fields that say something its other fields do not. */
    private fun withSmart(fields: List<SpecField>, smart: List<SpecField>?): List<SpecField> {
        val known = fields.map { it.value.lowercase() }.toSet()
        return fields + smart.orEmpty().filter { it.value.lowercase() !in known }
    }

    private fun memoryNotices(privilegedRan: Boolean, dimm: String?, modules: List<SpecItem>): List<SpecNotice> = when {
        !privilegedRan -> listOf(SpecNotice.ModulesNeedRoot)
        dimm.orEmpty().trim() == SystemSpecsCommands.MISSING -> listOf(SpecNotice.ModulesToolMissing)
        modules.isEmpty() -> listOf(SpecNotice.NoModulesReported)
        else -> emptyList()
    }

    private fun driveNotices(privilegedRan: Boolean, smart: String?): List<SpecNotice> = when {
        !privilegedRan -> listOf(SpecNotice.DriveHealthNeedsRoot)
        smart.orEmpty().trim() == SystemSpecsCommands.MISSING -> listOf(SpecNotice.DriveHealthToolMissing)
        else -> emptyList()
    }

    private fun memorySummary(total: Long?, modules: List<SpecItem>, slots: Int?): String {
        val used = modules.count { it.summary != "Empty" }
        val slotText = when {
            modules.isEmpty() -> null
            else -> "$used of ${slots ?: modules.size} slots used"
        }
        val kind = modules.firstOrNull { it.summary != "Empty" }?.summary?.split(" · ")?.drop(1)?.take(2)?.joinToString(" ")
        return dotted(bytes(total), slotText, kind)
    }

    private fun flagsItem(flags: String?): SpecItem? = real(flags)?.let {
        val list = it.split(Regex("[\\s,]+")).filter { f -> f.isNotEmpty() }
        SpecItem("Flags", count(list.size, "flag", "flags"), listOf(SpecField("", list.joinToString(" "))))
    }

    /** ifconfig's interface blocks (FreeBSD, OpenBSD, macOS). [titles] names devices, e.g. en0 → Wi-Fi. */
    internal fun ifconfig(text: String?, titles: Map<String, String> = emptyMap(), adapters: Map<String, String> = emptyMap()): List<SpecItem> {
        val items = mutableListOf<SpecItem>()
        var name: String? = null
        var mtu: String? = null
        val lines = mutableListOf<Pair<String, String>>()
        fun flush() {
            val n = name ?: return
            val map = lines.groupBy({ it.first }, { it.second })
            val ether = map["ether"]?.firstOrNull() ?: map["lladdr"]?.firstOrNull()
            val virtual = listOf("lo", "bridge", "tap", "epair", "pflog", "pfsync", "enc", "gif", "stf", "utun", "awdl", "llw", "anpi", "ap")
                .any { n.startsWith(it) && n.drop(it.length).all(Char::isDigit) }
            if (ether != null && !virtual && (titles.isEmpty() || n in titles)) {
                val ipv4 = map["inet"].orEmpty().map { it.substringBefore(' ') }
                val ipv6 = map["inet6"].orEmpty().map { it.substringBefore(' ').substringBefore('%') }.filterNot { it.startsWith("fe80") }
                val status = map["status"]?.firstOrNull()
                val media = map["media"]?.firstOrNull()
                items += SpecItem(
                    titles[n]?.let { "$it ($n)" } ?: n,
                    dotted(media?.substringAfter('(', "")?.substringBefore(')')?.substringBefore(' '), status, ipv4.firstOrNull()),
                    listOfNotNull(
                        field("Adapter", adapters[n]),
                        field("MAC address", ether),
                        field("Status", status),
                        field("Media", media),
                        field("MTU", mtu),
                        field("IPv4", ipv4.joinToString(", ")),
                        field("IPv6", ipv6.joinToString(", ")),
                    ),
                )
            }
            name = null; mtu = null; lines.clear()
        }
        text.orEmpty().lineSequence().forEach { line ->
            val header = Regex("^([A-Za-z0-9_.]+): flags=").find(line)
            if (header != null) {
                flush()
                name = header.groupValues[1]
                mtu = Regex("mtu (\\d+)").find(line)?.groupValues?.get(1)
            } else if (line.startsWith("\t") || line.startsWith(" ")) {
                val t = line.trim()
                val key = t.substringBefore(' ').removeSuffix(":")
                lines += key to t.substringAfter(' ', "").trim()
            }
        }
        flush()
        return items
    }

    // ── Linux ───────────────────────────────────────────────────────────────────────────────

    private fun linux(s: Map<String, String>): SystemSpecs {
        val privilegedRan = "PRIV" in s
        val uptime = s["UPTIME"]?.substringBefore(' ')?.toDoubleOrNull()?.toLong()
        val smart = smartctl(s["SMART"])
        val df = RemoteParsers.parseDisks(s["DF"].orEmpty()).associateBy { it.mount }
        val pci = lspci(s["LSPCI"])
        return SystemSpecs(
            listOf(
                linuxSystem(s),
                linuxCpu(s),
                linuxMemory(s, privilegedRan),
                linuxStorage(s, smart, df, privilegedRan),
                linuxGpu(s, pci),
                linuxNetwork(s, pci),
            ),
            uptimeSeconds = uptime,
        )
    }

    private data class PciDevice(val slot: String, val kind: String, val vendor: String, val device: String)

    /** `lspci -mm`: slot "class" "vendor" "device" …; a sysfs slot ends with the short one. */
    private fun lspci(text: String?): List<PciDevice> =
        text.orEmpty().lineSequence().mapNotNull { line ->
            val m = Regex("^(\\S+)\\s+\"([^\"]*)\"\\s+\"([^\"]*)\"\\s+\"([^\"]*)\"").find(line) ?: return@mapNotNull null
            PciDevice(m.groupValues[1], m.groupValues[2], m.groupValues[3], m.groupValues[4])
        }.toList()

    private fun List<PciDevice>.at(slot: String?): PciDevice? =
        slot?.takeIf { it.isNotEmpty() }?.let { s -> firstOrNull { s.endsWith(it.slot) } }

    private fun linuxSystem(s: Map<String, String>): SpecSection {
        val release = keyValues(s["RELEASE"], '=').associate { (k, v) -> k to v.trim('"') }
        val uname = s["OS"].orEmpty().trim().split(Regex("\\s+"))
        val dmi = tabValues(s["DMI"])
        val virt = s["VIRT"]?.trim()?.takeIf { it.isNotEmpty() && it != "none" }
        val model = real(s["MODEL"])
        val os = release["PRETTY_NAME"] ?: release["NAME"]
        val maker = real(dmi["sys_vendor"])
        val product = joined(dmi["product_name"], dmi["product_version"])
        return SpecSection(
            SpecKind.System,
            summary = dotted(model ?: joined(maker, product), os),
            fields = listOfNotNull(
                field("Hostname", s["HOSTNAME"]?.lineSequence()?.firstOrNull()),
                field("Operating system", os),
                field("Kernel", uname.getOrNull(1)),
                field("Architecture", uname.getOrNull(2)),
                field("Virtualization", virt),
                field("Model", model),
                field("Manufacturer", maker),
                field("Product", product),
                field("Family", real(dmi["product_family"])),
                field("Motherboard", joined(dmi["board_vendor"], dmi["board_name"], dmi["board_version"])),
                field("BIOS", joined(dmi["bios_vendor"], dmi["bios_version"], dmi["bios_date"]?.let { "($it)" })),
                field("Chassis", dmi["chassis_type"]?.toIntOrNull()?.let { CHASSIS[it] }),
            ),
        )
    }

    private fun linuxCpu(s: Map<String, String>): SpecSection {
        val fields = mutableListOf<SpecField>()
        val vulnerabilities = mutableListOf<SpecField>()
        var flags: String? = null
        // lscpu nests related lines under a header with no value; Vulnerabilities is one of them.
        var group: String? = null
        var groupIndent = -1
        s["LSCPU"].orEmpty().lines().forEach { line ->
            if (line.isBlank() || ':' !in line) return@forEach
            val indent = line.length - line.trimStart().length
            if (group != null && indent <= groupIndent) group = null
            val key = line.substringBefore(':').trim()
            val value = line.substringAfter(':').trim()
            when {
                value.isEmpty() -> { group = key; groupIndent = indent }
                key == "Flags" -> flags = value
                key.startsWith("Vulnerability ") -> vulnerabilities += SpecField(key.removePrefix("Vulnerability "), value)
                group == "Vulnerabilities" -> vulnerabilities += SpecField(key, value)
                else -> fields += SpecField(key, value)
            }
        }
        // /proc/cpuinfo fills in what lscpu does not show (microcode, the Pi's board revision) or
        // everything, where there is no lscpu.
        val cpuinfo = keyValues(s["CPUINFO"])
        val haveLscpu = fields.isNotEmpty()
        cpuinfo.forEach { (k, v) ->
            when {
                k == "flags" || k == "Features" -> if (flags == null) flags = v
                k == "processor" || v.isEmpty() -> Unit
                haveLscpu && k !in setOf("microcode", "Hardware", "Revision", "bugs") -> Unit
                fields.none { it.label.equals(k, true) } -> fields += SpecField(k, v)
            }
        }
        if (vulnerabilities.isEmpty()) {
            s["VULN"].orEmpty().lineSequence().forEach { line ->
                val name = line.substringBefore(':').substringAfterLast('/')
                val value = line.substringAfter(':').trim()
                if (name.isNotEmpty() && value.isNotEmpty()) {
                    vulnerabilities += SpecField(name.replace('_', ' ').replaceFirstChar { it.uppercase() }, value)
                }
            }
        }
        val freq = tabValues(s["CPUFREQ"])
        val current = freq["scaling_cur_freq"].orEmpty().split(' ').mapNotNull { it.toLongOrNull()?.div(1000) }.filter { it > 0 }
        val frequency = listOfNotNull(
            field("Driver", freq["scaling_driver"]),
            field("Governor", freq["scaling_governor"]),
            field("Minimum", megahertz(freq["cpuinfo_min_freq"]?.toLongOrNull()?.div(1000))),
            field("Maximum", megahertz(freq["cpuinfo_max_freq"]?.toLongOrNull()?.div(1000))),
            field(
                "Now",
                current.takeIf { it.isNotEmpty() }?.let {
                    "${megahertz(it.min())} – ${megahertz(it.max())}, average ${megahertz(it.average().toLong())} across ${count(it.size, "core", "cores")}"
                },
            ),
        )
        val byLabel = fields.associate { it.label to it.value }
        val name = byLabel["Model name"] ?: byLabel["model name"] ?: byLabel["Hardware"]
        val sockets = byLabel["Socket(s)"]?.toIntOrNull() ?: 1
        val cores = (byLabel["Core(s) per socket"] ?: byLabel["Core(s) per cluster"])?.toIntOrNull()?.times(sockets)
        val threads = byLabel["CPU(s)"]?.toIntOrNull()
        return SpecSection(
            SpecKind.Cpu,
            summary = dotted(
                name,
                cores?.let { count(it, "core", "cores") },
                threads?.let { count(it, "thread", "threads") },
                megahertz(byLabel["CPU max MHz"]?.toDoubleOrNull()?.toLong()),
            ),
            fields = fields,
            items = listOfNotNull(
                frequency.takeIf { it.isNotEmpty() }?.let { SpecItem("Frequency scaling", dotted(freq["scaling_driver"], freq["scaling_governor"]), it) },
                vulnerabilities.takeIf { it.isNotEmpty() }?.let { v ->
                    val affected = v.count { !it.value.startsWith("Not affected", true) }
                    SpecItem("Vulnerabilities", "$affected of ${v.size} need mitigation", v)
                },
                flagsItem(flags),
            ),
        )
    }

    private fun linuxMemory(s: Map<String, String>, privilegedRan: Boolean): SpecSection {
        val kb = keyValues(s["MEMINFO"]).associate { (k, v) -> k to v.substringBefore(' ').toLongOrNull()?.times(1024) }
        val total = kb["MemTotal"]
        val available = kb["MemAvailable"]
        val (array, modules) = dmidecodeMemory(s["DIMM"].takeIf { privilegedRan })
        val hugeTotal = kb["HugePages_Total"]?.div(1024)
        val swaps = s["SWAPS"].orEmpty().lineSequence().mapNotNull { line ->
            val t = line.trim().split(Regex("\\s+"))
            if (t.size < 5) return@mapNotNull null
            SpecItem(
                t[0],
                dotted(t[1], bytes(t[2].toLongOrNull()?.times(1024))),
                listOfNotNull(
                    field("Type", t[1]),
                    field("Size", bytes(t[2].toLongOrNull()?.times(1024))),
                    field("Used", RemoteParsers.humanBytes(t[3].toLongOrNull()?.times(1024) ?: 0)),
                    field("Priority", t[4]),
                ),
            )
        }.toList()
        return SpecSection(
            SpecKind.Memory,
            summary = memorySummary(total, modules, array.find { it.label == "Number Of Devices" }?.value?.toIntOrNull()),
            fields = listOfNotNull(
                field("Total", bytes(total)),
                field("Available", bytes(available)),
                field("In use", bytes(if (total != null && available != null) total - available else null)),
                field("Free", bytes(kb["MemFree"])),
                field("Buffers", bytes(kb["Buffers"])),
                field("Cached", bytes(kb["Cached"])),
                field("Shared", bytes(kb["Shmem"])),
                field("Kernel slab", bytes(kb["Slab"])),
                field("Swap total", bytes(kb["SwapTotal"])),
                field("Swap free", bytes(kb["SwapFree"])),
                field("Committed", bytes(kb["Committed_AS"])),
                field("Commit limit", bytes(kb["CommitLimit"])),
                field("Huge pages", hugeTotal?.takeIf { it > 0 }?.let { "$it × ${bytes(kb["Hugepagesize"])}" }),
            ) + array,
            items = modules + swaps,
            notices = memoryNotices(privilegedRan, s["DIMM"], modules),
        )
    }

    /** lsblk -P's KEY="value" pairs, with lsblk's \xHH escapes decoded and PHY-SEC spelt PHY_SEC. */
    private fun lsblk(text: String?): List<Map<String, String>> =
        text.orEmpty().lineSequence().mapNotNull { line ->
            val pairs = Regex("([A-Z][A-Z_:-]*)=\"((?:[^\"\\\\]|\\\\.)*)\"").findAll(line).associate { m ->
                m.groupValues[1].replace('-', '_') to
                    Regex("\\\\x([0-9a-fA-F]{2})").replace(m.groupValues[2]) { it.groupValues[1].toInt(16).toChar().toString() }.trim()
            }
            pairs.takeIf { "NAME" in it }
        }.toList()

    private fun linuxStorage(s: Map<String, String>, smart: Map<String, List<SpecField>>, df: Map<String, DiskUsage>, privilegedRan: Boolean): SpecSection {
        val nodes = lsblk(s["BLOCK"])
        // A card reader or optical drive with nothing in it reports a size of 0.
        val drives = nodes.filter { n ->
            n["TYPE"] in setOf("disk", "rom") && listOf("loop", "ram", "zram").none { n.getValue("NAME").startsWith(it) } && n["SIZE"] != "0"
        }
        // Without PKNAME (older lsblk), a partition is named after its drive: sda1, nvme0n1p1, mmcblk0p1.
        fun children(parent: String): List<Map<String, String>> =
            nodes.filter { n -> if ("PKNAME" in n) n["PKNAME"] == parent else n["TYPE"] == "part" && n.getValue("NAME").startsWith(parent) && n["NAME"] != parent }
        val shownMounts = mutableSetOf<String>()
        fun describe(node: Map<String, String>, depth: Int, into: MutableList<SpecField>) {
            val mount = node["MOUNTPOINT"].orEmpty()
            if (mount.isNotEmpty()) shownMounts += mount
            into += SpecField(
                "  ".repeat(depth) + node.getValue("NAME"),
                dotted(
                    bytes(node["SIZE"]?.toLongOrNull()),
                    node["TYPE"]?.takeIf { it != "part" },
                    node["FSTYPE"],
                    node["LABEL"]?.takeIf { it.isNotEmpty() }?.let { "\"$it\"" },
                    mount,
                    df[mount]?.let(::usage),
                ),
            )
            children(node.getValue("NAME")).forEach { describe(it, depth + 1, into) }
        }
        val items = drives.map { d ->
            val name = d.getValue("NAME")
            val kind = when {
                d["TYPE"] == "rom" -> "Optical"
                name.startsWith("nvme") || d["TRAN"] == "nvme" -> "NVMe SSD"
                name.startsWith("mmcblk") -> "SD/eMMC"
                d["ROTA"] == "0" -> "SSD"
                d["ROTA"] == "1" -> "HDD"
                else -> null
            }
            val partitions = mutableListOf<SpecField>()
            children(name).forEach { describe(it, 0, partitions) }
            val model = joined(d["VENDOR"], d["MODEL"])
            val health = smart[name]?.find { it.label == "SMART health" }?.value
            SpecItem(
                listOfNotNull(name, model).joinToString(" — "),
                dotted(bytes(d["SIZE"]?.toLongOrNull()), kind, d["TRAN"]?.uppercase(), health),
                withSmart(
                    listOfNotNull(
                        field("Model", real(d["MODEL"])),
                        field("Vendor", real(d["VENDOR"])),
                        field("Serial number", real(d["SERIAL"])),
                        field("Firmware", real(d["REV"])),
                        field("Size", d["SIZE"]?.toLongOrNull()?.let { "${RemoteParsers.humanBytes(it)} (${"%,d".format(java.util.Locale.US, it)} bytes)" }),
                        field("Type", kind),
                        field("Interface", d["TRAN"]?.uppercase()),
                        field("Removable", if (d["RM"] == "1") "Yes" else null),
                        field("Sector size", joined(d["LOG_SEC"]?.let { "$it B logical" }, d["PHY_SEC"]?.let { "$it B physical" }, separator = ", ")),
                    ) + partitions,
                    smart[name],
                ),
            )
        }
        // Mounts that are not on a local drive: network shares, ZFS datasets, and the like.
        val other = df.values.filter { it.mount !in shownMounts }.map { SpecField(it.mount, dotted(it.filesystem, usage(it))) }
        val total = drives.filter { it["TYPE"] == "disk" }.sumOf { it["SIZE"]?.toLongOrNull() ?: 0L }
        return SpecSection(
            SpecKind.Storage,
            summary = dotted(drives.takeIf { it.isNotEmpty() }?.let { count(it.size, "drive", "drives") }, bytes(total)),
            items = items + listOfNotNull(other.takeIf { it.isNotEmpty() }?.let { SpecItem("Other filesystems", count(it.size, "mount", "mounts"), it) }),
            notices = if (drives.isEmpty()) emptyList() else driveNotices(privilegedRan, s["SMART"]),
        )
    }

    private fun linuxGpu(s: Map<String, String>, pci: List<PciDevice>): SpecSection {
        val nvidia = s["NVIDIA"].orEmpty().lineSequence().map { line -> line.split(',').map { it.trim() } }
            .filter { it.size >= 2 }.associateBy { it[0].lowercase().takeLast(7) }
        val seen = mutableSetOf<String>()
        val items = s["DRM"].orEmpty().lineSequence().mapNotNull { line ->
            val t = line.split('\t')
            if (t.size < 6) return@mapNotNull null
            val vendorId = t[1]
            val deviceId = t[2]
            val driver = t[3]
            val vram = t[4]
            val slot = t[5]
            if (slot.isNotEmpty() && !seen.add(slot)) return@mapNotNull null
            val device = pci.at(slot)
            val nv = nvidia[slot.lowercase().takeLast(7)]
            val vendor = device?.vendor ?: PCI_VENDORS[vendorId.lowercase()]
            val name = nv?.getOrNull(1) ?: device?.device ?: joined(vendor, deviceId) ?: driver
            val memory = nv?.getOrNull(3) ?: bytes(vram.toLongOrNull())
            SpecItem(
                name,
                dotted(memory, driver),
                listOfNotNull(
                    field("Vendor", vendor),
                    field("Device", device?.device),
                    field("Driver", driver),
                    field("Driver version", nv?.getOrNull(2)),
                    field("Video memory", memory),
                    field("VBIOS", nv?.getOrNull(4)),
                    field("PCIe link", nv?.let { joined(it.getOrNull(5)?.let { g -> "Gen $g" }, it.getOrNull(6)?.let { w -> "x$w" }) }),
                    field("Power limit", nv?.getOrNull(7)),
                    field("Temperature", nv?.getOrNull(8)?.let { "$it °C" }),
                    field("PCI slot", slot),
                ),
            )
        }.toList()
        // Display controllers with no driver loaded have no DRM card, but lspci still lists them.
        val unbound = pci.filter { it.kind.contains("VGA", true) || it.kind.contains("3D", true) || it.kind.contains("Display", true) }
            .filter { p -> seen.none { it.endsWith(p.slot) } }
            .map { p -> SpecItem(p.device, dotted(p.vendor, "no driver loaded"), listOf(SpecField("Vendor", p.vendor), SpecField("PCI slot", p.slot))) }
        val nvidiaSmiMissing = s["NVIDIA"].orEmpty().trim() == SystemSpecsCommands.MISSING
        return gpuSection(items + unbound, listOfNotNull(SpecNotice.GpuToolMissing.takeIf { nvidiaSmiMissing }))
    }

    private fun linuxNetwork(s: Map<String, String>, pci: List<PciDevice>): SpecSection {
        val addresses = s["ADDR"].orEmpty().lineSequence().mapNotNull { line ->
            val t = line.trim().split(Regex("\\s+"))
            if (t.size < 4 || (t[2] != "inet" && t[2] != "inet6")) null else Triple(t[1].substringBefore('@'), t[2], t[3])
        }.filterNot { it.third.startsWith("fe80") }.groupBy { it.first }
        val items = s["NET"].orEmpty().lineSequence().mapNotNull { line ->
            // The last column (wireless) is empty for wired adapters, and a trimmed line drops it.
            val t = line.split('\t')
            if (t.size < 7) return@mapNotNull null
            val name = t[0]
            val adapter = pci.at(t[6])
            val ipv4 = addresses[name].orEmpty().filter { it.second == "inet" }.map { it.third }
            val ipv6 = addresses[name].orEmpty().filter { it.second == "inet6" }.map { it.third }
            val speed = linkSpeed(t[3].toLongOrNull())
            SpecItem(
                name,
                dotted(speed, t[2], ipv4.firstOrNull()),
                listOfNotNull(
                    field("Adapter", adapter?.device),
                    field("Vendor", adapter?.vendor),
                    field("Kind", if (t.getOrNull(7) == "wireless") "Wireless" else null),
                    field("MAC address", t[1]),
                    field("State", t[2]),
                    field("Speed", speed),
                    field("MTU", t[4]),
                    field("Driver", t[5]),
                    field("IPv4", ipv4.joinToString(", ")),
                    field("IPv6", ipv6.joinToString(", ")),
                    field("PCI slot", t[6].takeIf { adapter != null }),
                ),
            )
        }.toList()
        return networkSection(items)
    }

    private fun gpuSection(gpus: List<SpecItem>, notices: List<SpecNotice> = emptyList()) =
        SpecSection(SpecKind.Gpu, summary = gpus.joinToString(", ") { it.title }, items = gpus, notices = notices)

    private fun networkSection(nics: List<SpecItem>) =
        SpecSection(SpecKind.Network, summary = count(nics.size, "adapter", "adapters").takeIf { nics.isNotEmpty() }.orEmpty(), items = nics)

    private fun uptimeSince(boot: Long?, now: Long?): Long? = if (boot != null && now != null && now > boot) now - boot else null

    // ── FreeBSD / OpenBSD ───────────────────────────────────────────────────────────────────

    private fun bsd(s: Map<String, String>): SystemSpecs {
        val privilegedRan = "PRIV" in s
        val sys = tabValues(s["SYSCTL"])
        val uname = s["OS"].orEmpty().trim().split(Regex("\\s+"))
        val boot = Regex("sec = (\\d+)").find(sys["kern.boottime"].orEmpty())?.groupValues?.get(1)?.toLongOrNull()
        val now = s["NOW"]?.trim()?.toLongOrNull()
        val smart = smartctl(s["SMART"])
        val pci = pciconf(s["PCI"])

        val system = SpecSection(
            SpecKind.System,
            summary = dotted(joined(sys["smbios.system.maker"] ?: sys["hw.vendor"], sys["smbios.system.product"] ?: sys["hw.product"]), uname.firstOrNull()),
            fields = listOfNotNull(
                field("Hostname", s["HOSTNAME"]),
                field("Operating system", joined(uname.getOrNull(0), s["RELEASE"]?.trim() ?: uname.getOrNull(1))),
                field("Architecture", sys["hw.machine_arch"] ?: uname.getOrNull(2)),
                field("Virtualization", sys["kern.vm_guest"]?.takeIf { it != "none" }),
                field("Manufacturer", real(sys["smbios.system.maker"] ?: sys["hw.vendor"])),
                field("Product", joined(sys["smbios.system.product"] ?: sys["hw.product"], sys["smbios.system.version"] ?: sys["hw.version"])),
                field("Motherboard", joined(sys["smbios.planar.maker"], sys["smbios.planar.product"])),
                field("BIOS", joined(sys["smbios.bios.vendor"], sys["smbios.bios.version"], sys["smbios.bios.reldate"]?.let { "($it)" })),
            ),
        )

        val dmesg = s["DMESG"].orEmpty().lines()
        val origin = dmesg.firstOrNull { it.trim().startsWith("Origin") }.orEmpty()
        fun originValue(key: String) = Regex("$key=\"?([^\"\\s]+)").find(origin)?.groupValues?.get(1)
        val flags = dmesg.filter { it.contains("Features") }.flatMap { line ->
            Regex("<([^>]*)>").find(line)?.groupValues?.get(1)?.split(',').orEmpty()
        }.joinToString(" ")
        val cpus = (sys["kern.smp.cpus"] ?: sys["hw.ncpu"])?.toIntOrNull()
        val cores = sys["kern.smp.cores"]?.toIntOrNull()
        val levels = sys["dev.cpu.0.freq_levels"]?.split(' ')?.mapNotNull { it.substringBefore('/').toLongOrNull() }.orEmpty()
        val cpu = SpecSection(
            SpecKind.Cpu,
            summary = dotted(sys["hw.model"], cores?.let { count(it, "core", "cores") }, cpus?.let { count(it, "thread", "threads") }),
            fields = listOfNotNull(
                field("Model", sys["hw.model"]),
                field("Architecture", sys["hw.machine_arch"] ?: sys["hw.machine"]),
                field("Vendor", originValue("Origin")),
                field("Family", originValue("Family")),
                field("Model ID", originValue("Model")),
                field("Stepping", originValue("Stepping")),
                field("Logical CPUs", cpus?.toString()),
                field("Cores", cores?.toString()),
                field("Threads per core", sys["kern.smp.threads_per_core"]),
                field("Clock", megahertz((sys["hw.clockrate"] ?: sys["hw.cpuspeed"])?.toLongOrNull())),
                field("Current frequency", megahertz(sys["dev.cpu.0.freq"]?.toLongOrNull())),
                field("Frequency steps", levels.takeIf { it.isNotEmpty() }?.let { "${megahertz(it.min())} – ${megahertz(it.max())} (${it.size} steps)" }),
            ),
            items = listOfNotNull(flagsItem(flags)),
        )

        val (array, modules) = dmidecodeMemory(s["DIMM"].takeIf { privilegedRan })
        val physical = sys["hw.physmem"]?.toLongOrNull()
        val swaps = s["SWAP"].orEmpty().lineSequence().mapNotNull { line ->
            val t = line.trim().split(Regex("\\s+"))
            if (t.size < 4) null else SpecItem(
                t[0], bytes(t[1].toLongOrNull()?.times(1024)).orEmpty(),
                listOfNotNull(field("Size", bytes(t[1].toLongOrNull()?.times(1024))), field("Used", RemoteParsers.humanBytes(t[2].toLongOrNull()?.times(1024) ?: 0))),
            )
        }.toList()
        val memory = SpecSection(
            SpecKind.Memory,
            summary = memorySummary(physical, modules, array.find { it.label == "Number Of Devices" }?.value?.toIntOrNull()),
            fields = listOfNotNull(
                field("Physical", bytes(physical)),
                field("Installed", bytes(sys["hw.realmem"]?.toLongOrNull())),
                field("Usable", bytes(sys["hw.usermem"]?.toLongOrNull())),
                field("Page size", sys["hw.pagesize"]?.let { "$it B" }),
            ) + array,
            items = modules + swaps,
            notices = memoryNotices(privilegedRan, s["DIMM"], modules),
        )

        val df = RemoteParsers.parseDisks(s["DF"].orEmpty(), blockBytes = 1024)
        val fsTypes = mountTypes(s["MOUNT"])
        val geoms = geom(s["GEOM"])
        val diskNames = geoms.map { it.first }.ifEmpty {
            (sys["kern.disks"]?.split(' ') ?: sys["hw.disknames"]?.split(',')?.map { it.substringBefore(':') }).orEmpty().filter { it.isNotEmpty() }
        }
        val drives = diskNames.map { name ->
            val g = geoms.find { it.first == name }?.second.orEmpty()
            val size = g["Mediasize"]?.substringBefore(' ')?.toLongOrNull()
            val rotation = g["rotationrate"]?.toIntOrNull()
            val kind = when {
                name.startsWith("nvd") || name.startsWith("nda") -> "NVMe SSD"
                rotation == 0 -> "SSD"
                rotation != null && rotation > 1 -> "HDD"
                else -> null
            }
            val health = smart[name]?.find { it.label == "SMART health" }?.value
            SpecItem(
                listOfNotNull(name, real(g["descr"])).joinToString(" — "),
                dotted(bytes(size), kind, health),
                withSmart(
                    listOfNotNull(
                        field("Model", real(g["descr"])),
                        field("Serial number", real(g["ident"])),
                        field("Size", bytes(size)),
                        field("Type", kind),
                        field("Rotation", rotation?.takeIf { it > 1 }?.let { "$it rpm" }),
                        field("Sector size", g["Sectorsize"]?.let { "$it B" }),
                        field("Stripe size", g["Stripesize"]?.takeIf { it != "0" }?.let { "$it B" }),
                        field("LUN ID", g["lunid"]),
                    ),
                    smart[name],
                ),
            )
        }
        val filesystems = df.map { SpecField(it.mount, dotted(it.filesystem, fsTypes[it.mount], usage(it))) }
        val storage = SpecSection(
            SpecKind.Storage,
            summary = dotted(drives.takeIf { it.isNotEmpty() }?.let { count(it.size, "drive", "drives") }),
            items = drives + listOfNotNull(filesystems.takeIf { it.isNotEmpty() }?.let { SpecItem("Filesystems", count(it.size, "mount", "mounts"), it) }),
            notices = if (drives.isEmpty()) emptyList() else driveNotices(privilegedRan, s["SMART"]),
        )

        val gpus = pci.filter { it.fields["class"] == "display" }.map { p ->
            SpecItem(
                p.fields["device"] ?: p.driver,
                dotted(p.fields["vendor"], p.driver),
                listOfNotNull(field("Vendor", p.fields["vendor"]), field("Device", p.fields["device"]), field("Driver", p.driver), field("PCI slot", p.slot)),
            )
        }
        val adapters = pci.filter { it.fields["class"] == "network" }.associate { it.driver to (it.fields["device"] ?: "") }
        val nics = ifconfig(s["IFCONFIG"], adapters = adapters)
        return SystemSpecs(
            listOf(
                system, cpu, memory, storage,
                gpuSection(gpus),
                networkSection(nics),
            ),
            uptimeSeconds = uptimeSince(boot, now),
        )
    }

    /** `geom disk list`: one block per drive, "Geom name: ada0" then "   Key: value" lines. */
    private fun geom(text: String?): List<Pair<String, Map<String, String>>> =
        text.orEmpty().split(Regex("(?m)^Geom name: ")).drop(1).map { block ->
            block.lineSequence().first().trim() to keyValues(block.lineSequence().drop(1).joinToString("\n")).associate { (k, v) ->
                k.removePrefix("1. ").trim() to v
            }
        }

    /** Mount point → filesystem type, from `mount -p` (FreeBSD) or `mount` (OpenBSD). */
    private fun mountTypes(text: String?): Map<String, String> =
        text.orEmpty().lineSequence().mapNotNull { line ->
            Regex("^\\S+ on (\\S+) type (\\S+)").find(line)?.let { it.groupValues[1] to it.groupValues[2] }
                ?: line.trim().split(Regex("\\s+")).takeIf { it.size >= 3 }?.let { it[1] to it[2] }
        }.toMap()

    private data class PciConf(val driver: String, val slot: String, val fields: Map<String, String>)

    /** `pciconf -lv`: "em0@pci0:0:25:0: class=…" then indented "vendor = 'Intel Corporation'" lines. */
    private fun pciconf(text: String?): List<PciConf> =
        text.orEmpty().split(Regex("(?m)^(?=\\S)")).mapNotNull { block ->
            val header = Regex("^(\\S+?)@(pci[0-9:]+):").find(block) ?: return@mapNotNull null
            val fields = block.lineSequence().drop(1).mapNotNull { line ->
                val at = line.indexOf('=')
                if (at <= 0) null else line.substring(0, at).trim() to line.substring(at + 1).trim().trim('\'')
            }.toMap()
            PciConf(header.groupValues[1], header.groupValues[2], fields)
        }

    // ── macOS ───────────────────────────────────────────────────────────────────────────────

    /** One line of system_profiler's indented text: a group when [value] is null. */
    private class ProfilerNode(val key: String, val value: String?, val indent: Int) {
        val children = mutableListOf<ProfilerNode>()
        fun child(key: String) = children.find { it.key == key }
        fun leaves(): List<SpecField> = children.filter { it.value != null }.map { SpecField(it.key, it.value!!) }

        /** Every leaf below, with nested groups' names in front of their fields. */
        fun allLeaves(prefix: String = ""): List<SpecField> = children.flatMap { c ->
            if (c.value != null) listOf(SpecField(prefix + c.key, c.value)) else c.allLeaves("$prefix${c.key} · ")
        }
    }

    private fun profiler(text: String?): ProfilerNode {
        val root = ProfilerNode("", null, -1)
        val stack = ArrayDeque<ProfilerNode>().apply { addLast(root) }
        text.orEmpty().lineSequence().filter { it.isNotBlank() }.forEach { line ->
            val indent = line.length - line.trimStart().length
            val t = line.trim()
            val node = when {
                t.endsWith(":") -> ProfilerNode(t.dropLast(1), null, indent)
                ": " in t -> ProfilerNode(t.substringBefore(": "), t.substringAfter(": "), indent)
                else -> return@forEach
            }
            while (stack.last() !== root && stack.last().indent >= indent) stack.removeLast()
            stack.last().children += node
            if (node.value == null) stack.addLast(node)
        }
        return root
    }

    private fun darwin(s: Map<String, String>): SystemSpecs {
        val sys = tabValues(s["SYSCTL"])
        val sw = keyValues(s["SWVERS"]).toMap()
        val uname = s["OS"].orEmpty().trim().split(Regex("\\s+"))
        val tree = profiler(s["PROFILER"])
        val overview = tree.child("Hardware")?.child("Hardware Overview")?.leaves().orEmpty()
        val cpuKeys = setOf("Chip", "Processor Name", "Processor Speed", "Number of Processors", "Total Number of Cores", "L2 Cache (per Core)", "L2 Cache", "L3 Cache", "Hyper-Threading Technology")
        val boot = Regex("sec = (\\d+)").find(sys["kern.boottime"].orEmpty())?.groupValues?.get(1)?.toLongOrNull()
        val now = s["NOW"]?.trim()?.toLongOrNull()
        val model = overview.find { it.label == "Model Name" }?.value

        val system = SpecSection(
            SpecKind.System,
            summary = dotted(model, joined(sw["ProductName"], sw["ProductVersion"])),
            fields = listOfNotNull(
                field("Hostname", s["HOSTNAME"]),
                field("Operating system", joined(sw["ProductName"], sw["ProductVersion"], sw["BuildVersion"]?.let { "($it)" })),
                field("Kernel", joined(uname.getOrNull(0), uname.getOrNull(1))),
                field("Architecture", uname.getOrNull(2)),
                field("Virtualization", if (sys["kern.hv_vmm_present"] == "1") "Virtual machine" else null),
            ) + overview.filter { it.label !in cpuKeys && it.label != "Memory" },
        )

        val chip = overview.find { it.label == "Chip" || it.label == "Processor Name" }?.value
        val cores = sys["hw.physicalcpu"]?.toIntOrNull()
        val threads = sys["hw.logicalcpu"]?.toIntOrNull()
        val cpu = SpecSection(
            SpecKind.Cpu,
            summary = dotted(sys["machdep.cpu.brand_string"] ?: chip, cores?.let { count(it, "core", "cores") }, threads?.let { count(it, "thread", "threads") }),
            fields = listOfNotNull(
                field("Model", sys["machdep.cpu.brand_string"]),
                field("Vendor", sys["machdep.cpu.vendor"]),
                field("Family", sys["machdep.cpu.family"]),
                field("Model ID", sys["machdep.cpu.model"]),
                field("Stepping", sys["machdep.cpu.stepping"]),
                field("Microcode", sys["machdep.cpu.microcode_version"]),
                field("Cores", cores?.toString()),
                field("Threads", threads?.toString()),
                field(sys["hw.perflevel0.name"]?.let { "$it cores" } ?: "Performance cores", sys["hw.perflevel0.physicalcpu"]),
                field(sys["hw.perflevel1.name"]?.let { "$it cores" } ?: "Efficiency cores", sys["hw.perflevel1.physicalcpu"]),
                field("Frequency", megahertz(sys["hw.cpufrequency"]?.toLongOrNull()?.div(1_000_000))),
                field("Maximum frequency", megahertz(sys["hw.cpufrequency_max"]?.toLongOrNull()?.div(1_000_000))),
                field("L1 instruction cache", bytes(sys["hw.l1icachesize"]?.toLongOrNull())),
                field("L1 data cache", bytes(sys["hw.l1dcachesize"]?.toLongOrNull())),
                field("L2 cache", bytes(sys["hw.l2cachesize"]?.toLongOrNull())),
                field("L3 cache", bytes(sys["hw.l3cachesize"]?.toLongOrNull())),
            ) + overview.filter { it.label in cpuKeys },
            items = listOfNotNull(flagsItem(joined(sys["machdep.cpu.features"], sys["machdep.cpu.leaf7_features"], sys["machdep.cpu.extfeatures"]))),
        )

        val memoryNode = tree.child("Memory")
        val slots = memoryNode?.child("Memory Slots")
        val modules = (slots ?: memoryNode)?.children.orEmpty().filter { it.value == null }.map { bank ->
            val f = bank.leaves()
            fun v(k: String) = f.find { it.label == k }?.value
            val empty = v("Size")?.startsWith("Empty", true) == true
            SpecItem(bank.key, if (empty) "Empty" else dotted(v("Size"), v("Type"), v("Speed"), v("Manufacturer")), if (empty) emptyList() else f)
        }
        val total = sys["hw.memsize"]?.toLongOrNull()
        val memory = SpecSection(
            SpecKind.Memory,
            summary = memorySummary(total, modules, null).ifEmpty { dotted(bytes(total)) },
            fields = listOfNotNull(field("Total", bytes(total)), field("Page size", sys["hw.pagesize"]?.let { "$it B" }), field("Swap", sys["vm.swapusage"])) +
                (slots?.leaves() ?: memoryNode?.leaves()).orEmpty(),
            items = modules,
        )

        val volumes = tree.child("Storage")?.children.orEmpty().filter { it.value == null }.map { volume ->
            val f = volume.allLeaves()
            fun v(k: String) = f.find { it.label.endsWith(k) }?.value
            SpecItem(volume.key, dotted(v("Capacity")?.substringBefore(" ("), v("File System"), v("Free")?.substringBefore(" (")?.let { "$it free" }), f)
        }
        val storage = SpecSection(SpecKind.Storage, summary = count(volumes.size, "volume", "volumes").takeIf { volumes.isNotEmpty() }.orEmpty(), items = volumes)

        val gpus = tree.child("Graphics/Displays")?.children.orEmpty().filter { it.value == null }.map { g ->
            val f = g.allLeaves()
            SpecItem(g.key, dotted(f.find { it.label == "VRAM (Dynamic, Max)" || it.label == "VRAM (Total)" }?.value, f.find { it.label == "Total Number of Cores" }?.value?.let { "$it cores" }), f)
        }

        val ports = mutableMapOf<String, String>()
        var port: String? = null
        keyValues(s["HWPORTS"]).forEach { (k, v) ->
            when (k) {
                "Hardware Port" -> port = v
                "Device" -> port?.let { ports[v] = it }
            }
        }
        val nics = ifconfig(s["IFCONFIG"], titles = ports)
        return SystemSpecs(
            listOf(
                system, cpu, memory, storage,
                gpuSection(gpus),
                networkSection(nics),
            ),
            uptimeSeconds = uptimeSince(boot, now),
        )
    }

    // ── Windows ─────────────────────────────────────────────────────────────────────────────

    private fun records(text: String?): List<Map<String, String>> =
        text.orEmpty().split("##ITEM").map { block -> keyValues(block, '=').toMap() }.filter { it.isNotEmpty() }

    private val MEMORY_TYPES = mapOf(
        20 to "DDR", 21 to "DDR2", 22 to "DDR2 FB-DIMM", 24 to "DDR3", 26 to "DDR4", 27 to "LPDDR", 28 to "LPDDR2",
        29 to "LPDDR3", 30 to "LPDDR4", 34 to "DDR5", 35 to "LPDDR5",
    )
    private val FORM_FACTORS = mapOf(8 to "DIMM", 12 to "SODIMM", 13 to "SRIMM", 9 to "RIMM", 11 to "Row of chips")
    private val NIC_STATUS = mapOf(0 to "Disconnected", 1 to "Connecting", 2 to "Connected", 7 to "Media disconnected", 3 to "Disconnecting")

    private fun windows(s: Map<String, String>): SystemSpecs {
        val os = records(s["OS"]).firstOrNull().orEmpty()
        val cs = records(s["CS"]).firstOrNull().orEmpty()
        val bios = records(s["BIOS"]).firstOrNull().orEmpty()
        val board = records(s["BOARD"]).firstOrNull().orEmpty()

        val system = SpecSection(
            SpecKind.System,
            summary = dotted(joined(cs["Manufacturer"], cs["Model"]), os["Caption"]),
            fields = listOfNotNull(
                field("Hostname", os["CSName"]),
                field("Operating system", os["Caption"]),
                field("Version", joined(os["Version"], os["BuildNumber"]?.let { "(build $it)" })),
                field("Architecture", os["OSArchitecture"]),
                field("Manufacturer", real(cs["Manufacturer"])),
                field("Model", real(cs["Model"])),
                field("Family", real(cs["SystemFamily"])),
                field("System type", cs["SystemType"]),
                field("Motherboard", joined(board["Manufacturer"], board["Product"], board["Version"])),
                field("BIOS", joined(bios["Manufacturer"], bios["SMBIOSBIOSVersion"], bios["ReleaseDate"]?.let { "($it)" })),
                field("Hypervisor present", if (cs["HypervisorPresent"] == "True") "Yes" else null),
                field("Domain", cs["Domain"]),
                field("Installed", os["InstallDate"]),
                field("Last boot", os["LastBootUpTime"]),
            ),
        )

        val processors = records(s["CPU"])
        fun cpuFields(p: Map<String, String>) = listOfNotNull(
            field("Model", p["Name"]),
            field("Manufacturer", p["Manufacturer"]),
            field("Description", p["Description"]),
            field("Socket", p["SocketDesignation"]),
            field("Cores", p["NumberOfCores"]),
            field("Logical processors", p["NumberOfLogicalProcessors"]),
            field("Maximum clock", megahertz(p["MaxClockSpeed"]?.toLongOrNull())),
            field("Current clock", megahertz(p["CurrentClockSpeed"]?.toLongOrNull())),
            field("L2 cache", bytes(p["L2CacheSize"]?.toLongOrNull()?.times(1024))),
            field("L3 cache", bytes(p["L3CacheSize"]?.toLongOrNull()?.times(1024))),
            field("Address width", p["AddressWidth"]?.let { "$it-bit" }),
            field("Virtualization in firmware", p["VirtualizationFirmwareEnabled"]?.let { if (it == "True") "Enabled" else "Disabled" }),
            field("Second-level address translation", p["SecondLevelAddressTranslationExtensions"]?.let { if (it == "True") "Yes" else "No" }),
        )
        val first = processors.firstOrNull().orEmpty()
        val cpu = SpecSection(
            SpecKind.Cpu,
            summary = dotted(
                first["Name"],
                processors.sumOf { it["NumberOfCores"]?.toIntOrNull() ?: 0 }.takeIf { it > 0 }?.let { count(it, "core", "cores") },
                processors.sumOf { it["NumberOfLogicalProcessors"]?.toIntOrNull() ?: 0 }.takeIf { it > 0 }?.let { count(it, "thread", "threads") },
            ),
            fields = if (processors.size == 1) cpuFields(first) else emptyList(),
            items = if (processors.size > 1) processors.mapIndexed { i, p -> SpecItem(p["SocketDesignation"] ?: "Processor ${i + 1}", p["Name"].orEmpty(), cpuFields(p)) } else emptyList(),
        )

        val array = records(s["MEMARRAY"]).firstOrNull().orEmpty()
        val modules = records(s["DIMM"]).map { m ->
            val type = m["SMBIOSMemoryType"]?.toIntOrNull()?.let { MEMORY_TYPES[it] }
            val speed = (m["ConfiguredClockSpeed"] ?: m["Speed"])?.let { "$it MT/s" }
            val size = bytes(m["Capacity"]?.toLongOrNull())
            SpecItem(
                joined(m["DeviceLocator"], m["BankLabel"], separator = " · ") ?: "Module",
                dotted(size, type, speed, real(m["Manufacturer"])),
                listOfNotNull(
                    field("Size", size),
                    field("Type", type),
                    field("Form factor", m["FormFactor"]?.toIntOrNull()?.let { FORM_FACTORS[it] }),
                    field("Speed", m["Speed"]?.let { "$it MT/s" }),
                    field("Configured speed", m["ConfiguredClockSpeed"]?.let { "$it MT/s" }),
                    field("Voltage", m["ConfiguredVoltage"]?.toIntOrNull()?.takeIf { it > 0 }?.let { String.format(java.util.Locale.US, "%.2f V", it / 1000.0) }),
                    field("Manufacturer", real(m["Manufacturer"])),
                    field("Part number", real(m["PartNumber"])),
                ),
            )
        }
        val pageFiles = records(s["PAGEFILE"]).map { p ->
            SpecItem(p["Name"].orEmpty(), p["AllocatedBaseSize"]?.let { "$it MB" }.orEmpty(), listOfNotNull(
                field("Size", p["AllocatedBaseSize"]?.let { "$it MB" }), field("In use", p["CurrentUsage"]?.let { "$it MB" }), field("Peak", p["PeakUsage"]?.let { "$it MB" }),
            ))
        }
        val total = cs["TotalPhysicalMemory"]?.toLongOrNull()
        val slotCount = array["MemoryDevices"]?.toIntOrNull()
        val memory = SpecSection(
            SpecKind.Memory,
            summary = dotted(bytes(total), modules.takeIf { it.isNotEmpty() }?.let { "${it.size} of ${slotCount ?: it.size} slots used" },
                modules.firstOrNull()?.summary?.split(" · ")?.drop(1)?.take(2)?.joinToString(" ")),
            fields = listOfNotNull(
                field("Total", bytes(total)),
                field("Free", bytes(os["FreePhysicalMemory"]?.toLongOrNull()?.times(1024))),
                field("Slots", slotCount?.toString()),
                field("Maximum capacity", bytes(array["MaxCapacityEx"]?.toLongOrNull()?.times(1024))),
            ),
            items = modules + pageFiles,
        )

        val reliability = records(s["RELIABILITY"]).associateBy { it["DeviceId"] }
        val physical = records(s["PDISK"])
        val drives = if (physical.isNotEmpty()) {
            physical.map { d ->
                val r = reliability[d["DeviceId"]].orEmpty()
                val kind = d["MediaType"]?.takeIf { it != "Unspecified" }
                SpecItem(
                    d["FriendlyName"] ?: "Disk ${d["DeviceId"]}",
                    dotted(bytes(d["Size"]?.toLongOrNull()), kind, d["BusType"], d["HealthStatus"]),
                    listOfNotNull(
                        field("Size", bytes(d["Size"]?.toLongOrNull())),
                        field("Type", kind),
                        field("Interface", d["BusType"]),
                        field("Health", d["HealthStatus"]),
                        field("Status", d["OperationalStatus"]),
                        field("Firmware", d["FirmwareVersion"]),
                        field("Rotation", d["SpindleSpeed"]?.toLongOrNull()?.takeIf { it in 1..100_000 }?.let { "$it rpm" }),
                        field("Temperature", r["Temperature"]?.takeIf { it != "0" }?.let { "$it °C" }),
                        field("Wear", r["Wear"]?.let { "$it%" }),
                        field("Power-on hours", r["PowerOnHours"]),
                        field("Read errors", r["ReadErrorsTotal"]),
                        field("Write errors", r["WriteErrorsTotal"]),
                    ),
                )
            }
        } else {
            records(s["DISKDRIVE"]).map { d ->
                SpecItem(
                    d["Model"] ?: "Disk ${d["Index"]}",
                    dotted(bytes(d["Size"]?.toLongOrNull()), d["InterfaceType"]),
                    listOfNotNull(
                        field("Size", bytes(d["Size"]?.toLongOrNull())), field("Interface", d["InterfaceType"]), field("Media", d["MediaType"]),
                        field("Firmware", d["FirmwareRevision"]), field("Partitions", d["Partitions"]),
                    ),
                )
            }
        }
        val volumes = records(s["VOLUME"]).map { v ->
            val size = v["Size"]?.toLongOrNull()
            val free = v["FreeSpace"]?.toLongOrNull()
            SpecField(
                joined(v["DeviceID"], v["VolumeName"]?.let { "($it)" }).orEmpty(),
                dotted(v["FileSystem"], if (size != null && free != null) usage(DiskUsage(v["DeviceID"].orEmpty(), v["FileSystem"].orEmpty(), size, size - free)) else null),
            )
        }
        val storage = SpecSection(
            SpecKind.Storage,
            summary = dotted(drives.takeIf { it.isNotEmpty() }?.let { count(it.size, "drive", "drives") }),
            items = drives + listOfNotNull(volumes.takeIf { it.isNotEmpty() }?.let { SpecItem("Volumes", count(it.size, "volume", "volumes"), it) }),
        )

        val gpus = records(s["GPU"]).map { g ->
            // AdapterRAM is a 32-bit value, so cards with 4 GB or more all report about 4 GB.
            val ram = g["AdapterRAM"]?.toLongOrNull()?.let { if (it >= 4_293_918_720L) "4 GB or more" else bytes(it) }
            SpecItem(
                g["Name"].orEmpty(),
                dotted(g["AdapterCompatibility"], ram),
                listOfNotNull(
                    field("Vendor", g["AdapterCompatibility"]),
                    field("Processor", g["VideoProcessor"]),
                    field("Video memory", ram),
                    field("Driver version", g["DriverVersion"]),
                    field("Driver date", g["DriverDate"]),
                    field("Resolution", joined(g["CurrentHorizontalResolution"], g["CurrentVerticalResolution"], separator = " × ")),
                    field("Refresh rate", g["CurrentRefreshRate"]?.let { "$it Hz" }),
                ),
            )
        }

        val config = records(s["NICCONF"]).associateBy { it["Index"] }
        val nics = records(s["NIC"]).map { n ->
            val c = config[n["Index"]].orEmpty()
            val addresses = c["IPAddress"].orEmpty().split(", ").filter { it.isNotEmpty() }
            val speed = linkSpeed(n["Speed"]?.toLongOrNull()?.div(1_000_000))
            val status = n["NetConnectionStatus"]?.toIntOrNull()?.let { NIC_STATUS[it] }
            SpecItem(
                n["NetConnectionID"] ?: n["Name"].orEmpty(),
                dotted(speed, status, addresses.firstOrNull { ':' !in it }),
                listOfNotNull(
                    field("Adapter", n["Name"]),
                    field("Manufacturer", n["Manufacturer"]),
                    field("MAC address", n["MACAddress"]),
                    field("Status", status),
                    field("Speed", speed),
                    field("IPv4", addresses.filter { ':' !in it }.joinToString(", ")),
                    field("IPv6", addresses.filter { ':' in it && !it.startsWith("fe80") }.joinToString(", ")),
                    field("Gateway", c["DefaultIPGateway"]),
                    field("DNS servers", c["DNSServerSearchOrder"]),
                    field("DHCP", c["DHCPEnabled"]?.let { if (it == "True") "Yes" else "No" }),
                ),
            )
        }
        return SystemSpecs(
            listOf(
                system, cpu, memory, storage,
                gpuSection(gpus),
                networkSection(nics),
            ),
        )
    }
}
