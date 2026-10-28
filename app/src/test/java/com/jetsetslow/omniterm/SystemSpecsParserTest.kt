package com.jetsetslow.omniterm

import com.jetsetslow.omniterm.data.SpecKind
import com.jetsetslow.omniterm.data.SpecNotice
import com.jetsetslow.omniterm.data.SystemSpecs
import com.jetsetslow.omniterm.data.SystemSpecsCommands
import com.jetsetslow.omniterm.data.SystemSpecsParser
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Each OS family's specs output, as its own tools print it, into the same sections. */
class SystemSpecsParserTest {

    private fun SystemSpecs.value(kind: SpecKind, label: String): String? =
        section(kind)?.fields?.find { it.label == label }?.value

    private fun SystemSpecs.item(kind: SpecKind, titleStart: String) =
        section(kind)?.items?.find { it.title.startsWith(titleStart) }

    private val linuxCommon = """
        @OS
        Linux 6.8.0-45-generic x86_64
        @HOSTNAME
        media-server
        @RELEASE
        PRETTY_NAME="Ubuntu 24.04.1 LTS"
        NAME="Ubuntu"
        @UPTIME
        93784.21 1000.00
        @VIRT
        none
        @DMI
        sys_vendor	Dell Inc.
        product_name	OptiPlex 7080
        product_version	Not Specified
        product_family	NA
        board_vendor	Dell Inc.
        board_name	0J37VM
        bios_vendor	Dell Inc.
        bios_version	1.24.0
        bios_date	03/12/2024
        chassis_type	3
        @MODEL

        @LSCPU
        Architecture:             x86_64
          CPU op-mode(s):         32-bit, 64-bit
        CPU(s):                   12
        Vendor ID:                GenuineIntel
          Model name:             Intel(R) Core(TM) i5-10400 CPU @ 2.90GHz
            Thread(s) per core:   2
            Core(s) per socket:   6
            Socket(s):            1
            CPU max MHz:          4300.0000
            Flags:                fpu vme de pse tsc
        Caches (sum of all):
          L2:                     1.5 MiB (6 instances)
        Vulnerabilities:
          Meltdown:               Not affected
          Spectre v2:             Mitigation; Enhanced / Automatic IBRS
        @CPUINFO
        processor	: 0
        microcode	: 0xf8
        @CPUFREQ
        scaling_driver	intel_pstate
        scaling_governor	powersave
        cpuinfo_max_freq	4300000
        scaling_cur_freq	800000 4300000 2100000
        @VULN
        @MEMINFO
        MemTotal:       16303428 kB
        MemFree:         1000000 kB
        MemAvailable:   12000000 kB
        SwapTotal:       4194300 kB
        @SWAPS
        /swap.img                               file		4194300		0		-2
        @BLOCK
        NAME="nvme0n1" PKNAME="" TYPE="disk" SIZE="512110190592" MODEL="Samsung SSD 970 EVO Plus 500GB" SERIAL="S4EVNX0N" VENDOR="" REV="2B2QEXM7" TRAN="nvme" ROTA="0" RM="0" FSTYPE="" LABEL="" MOUNTPOINT="" PHY-SEC="512" LOG-SEC="512"
        NAME="nvme0n1p1" PKNAME="nvme0n1" TYPE="part" SIZE="1127219200" MODEL="" SERIAL="" VENDOR="" REV="" TRAN="nvme" ROTA="0" RM="0" FSTYPE="vfat" LABEL="" MOUNTPOINT="/boot/efi" PHY-SEC="512" LOG-SEC="512"
        NAME="nvme0n1p2" PKNAME="nvme0n1" TYPE="part" SIZE="510980587520" MODEL="" SERIAL="" VENDOR="" REV="" TRAN="nvme" ROTA="0" RM="0" FSTYPE="ext4" LABEL="root\x20disk" MOUNTPOINT="/" PHY-SEC="512" LOG-SEC="512"
        NAME="sdb" PKNAME="" TYPE="disk" SIZE="0" MODEL="SD/MMC/MS PRO" SERIAL="" VENDOR="Generic-" REV="1.00" TRAN="usb" ROTA="1" RM="1" FSTYPE="" LABEL="" MOUNTPOINT="" PHY-SEC="512" LOG-SEC="512"
        NAME="loop0" PKNAME="" TYPE="loop" SIZE="4096" MODEL="" SERIAL="" VENDOR="" REV="" TRAN="" ROTA="0" RM="0" FSTYPE="squashfs" LABEL="" MOUNTPOINT="/snap/core/1" PHY-SEC="512" LOG-SEC="512"
        @DF
        Filesystem     1-byte-blocks        Used    Available Capacity Mounted on
        /dev/nvme0n1p2 502468108288 100493621657 376373874688      22% /
        /dev/nvme0n1p1   1124999168      6291456   1118707712       1% /boot/efi
        nas:/export     4000000000000 2000000000000 2000000000000 50% /mnt/nas
        @DRM
        card0	0x8086	0x9bc8	i915		0000:00:02.0
        card1	0x10de	0x2204	nvidia		0000:01:00.0
        @LSPCI
        00:02.0 "VGA compatible controller" "Intel Corporation" "CometLake-S GT2 [UHD Graphics 630]" -r05 "Dell" "Device 09a4"
        01:00.0 "VGA compatible controller" "NVIDIA Corporation" "GA102 [GeForce RTX 3090]" -ra1 "NVIDIA" "Device 147d"
        00:1f.6 "Ethernet controller" "Intel Corporation" "Ethernet Connection (11) I219-LM" "Dell" "Device 09a4"
        @NVIDIA
        00000000:01:00.0, NVIDIA GeForce RTX 3090, 550.54.14, 24576 MiB, 94.02.42.00.A9, 4, 16, 350.00 W, 41
        @NET
        eno1	aa:bb:cc:dd:ee:ff	up	1000	1500	e1000e	0000:00:1f.6
        @ADDR
        1: lo    inet 127.0.0.1/8 scope host lo\       valid_lft forever
        2: eno1    inet 192.168.1.10/24 brd 192.168.1.255 scope global eno1\       valid_lft forever
        2: eno1    inet6 fe80::1/64 scope link \       valid_lft forever
    """.trimIndent()

    private val privileged = """
        @PRIV
        @DIMM
        # dmidecode 3.5

        Handle 0x003E, DMI type 16, 23 bytes
        Physical Memory Array
        ${'\t'}Location: System Board Or Motherboard
        ${'\t'}Error Correction Type: None
        ${'\t'}Maximum Capacity: 128 GB
        ${'\t'}Number Of Devices: 4

        Handle 0x003F, DMI type 17, 92 bytes
        Memory Device
        ${'\t'}Array Handle: 0x003E
        ${'\t'}Size: 16 GB
        ${'\t'}Form Factor: DIMM
        ${'\t'}Locator: DIMM1
        ${'\t'}Bank Locator: BANK 0
        ${'\t'}Type: DDR4
        ${'\t'}Speed: 3200 MT/s
        ${'\t'}Manufacturer: Kingston
        ${'\t'}Part Number: KHX3200C16D4/16GX
        ${'\t'}Asset Tag: Not Specified
        ${'\t'}Configured Memory Speed: 2666 MT/s

        Handle 0x0040, DMI type 17, 92 bytes
        Memory Device
        ${'\t'}Size: No Module Installed
        ${'\t'}Locator: DIMM2
        ${'\t'}Bank Locator: BANK 1
        @SMART
        ##DEV nvme0n1
        smartctl 7.4 2023-08-01 r5530 [x86_64-linux-6.8.0] (local build)
        === START OF INFORMATION SECTION ===
        Model Number:                       Samsung SSD 970 EVO Plus 500GB
        Firmware Version:                   2B2QEXM7
        Local Time is:                      Tue Oct 28 01:00:00 2026 UTC
        SMART overall-health self-assessment test result: PASSED
        Temperature:                        38 Celsius
        Percentage Used:                    3%
        Power On Hours:                     12,345
    """.trimIndent()

    @Test
    fun `linux system and cpu read lscpu with its nested groups`() {
        val specs = SystemSpecsParser.parse("Linux", linuxCommon)
        assertEquals("Ubuntu 24.04.1 LTS", specs.value(SpecKind.System, "Operating system"))
        assertEquals("6.8.0-45-generic", specs.value(SpecKind.System, "Kernel"))
        assertEquals("OptiPlex 7080", specs.value(SpecKind.System, "Product"))
        assertNull("Bare metal says nothing about virtualization", specs.value(SpecKind.System, "Virtualization"))
        assertEquals("Desktop", specs.value(SpecKind.System, "Chassis"))
        assertNull("NA is firmware filler", specs.value(SpecKind.System, "Family"))
        assertEquals(93784L, specs.uptimeSeconds)

        val cpu = specs.section(SpecKind.Cpu)!!
        assertEquals("Intel(R) Core(TM) i5-10400 CPU @ 2.90GHz · 6 cores · 12 threads · 4.30 GHz", cpu.summary)
        assertEquals("1.5 MiB (6 instances)", specs.value(SpecKind.Cpu, "L2"))
        assertEquals("0xf8", specs.value(SpecKind.Cpu, "microcode"))
        assertNull("Flags are their own item, not a field", specs.value(SpecKind.Cpu, "Flags"))
        assertEquals("1 of 2 need mitigation", specs.item(SpecKind.Cpu, "Vulnerabilities")!!.summary)
        assertEquals("5 flags", specs.item(SpecKind.Cpu, "Flags")!!.summary)
        val now = specs.item(SpecKind.Cpu, "Frequency")!!.fields.find { it.label == "Now" }!!.value
        assertEquals("800 MHz – 4.30 GHz, average 2.40 GHz across 3 cores", now)
    }

    @Test
    fun `linux without root says modules and drive health need it`() {
        val specs = SystemSpecsParser.parse("Linux", linuxCommon)
        assertEquals(listOf(SpecNotice.ModulesNeedRoot), specs.section(SpecKind.Memory)!!.notices)
        assertEquals(listOf(SpecNotice.DriveHealthNeedsRoot), specs.section(SpecKind.Storage)!!.notices)
        assertTrue(specs.wouldGainFromSudo)
        assertNull(specs.sudoError)
    }

    @Test
    fun `linux as root lists each memory slot and the drive's smart data`() {
        val specs = SystemSpecsParser.parse("Linux", "$privileged\n$linuxCommon")
        val memory = specs.section(SpecKind.Memory)!!
        assertTrue(memory.notices.isEmpty())
        assertFalse(specs.wouldGainFromSudo)
        assertEquals("15.5 GB · 1 of 4 slots used · DDR4 2666 MT/s", memory.summary)
        val dimm1 = specs.item(SpecKind.Memory, "DIMM1")!!
        assertEquals("DIMM1 · BANK 0", dimm1.title)
        assertEquals("KHX3200C16D4/16GX", dimm1.fields.find { it.label == "Part Number" }!!.value)
        assertTrue("Placeholders are dropped", dimm1.fields.none { it.label == "Asset Tag" })
        assertEquals("Empty", specs.item(SpecKind.Memory, "DIMM2")!!.summary)
        assertEquals("128 GB", specs.value(SpecKind.Memory, "Maximum Capacity"))

        val drive = specs.item(SpecKind.Storage, "nvme0n1")!!
        assertEquals("476.9 GB · NVMe SSD · NVME · PASSED", drive.summary)
        val labels = drive.fields.map { it.label }
        assertTrue("SMART adds wear and hours", "Percentage Used" in labels && "Power On Hours" in labels)
        assertFalse("The model smartctl repeats is shown once", "Model Number" in labels)
        assertFalse("smartctl's clock is not a drive property", "Local Time is" in labels)
        val root = drive.fields.find { it.label == "nvme0n1p2" }!!.value
        assertEquals("475.9 GB · ext4 · \"root disk\" · / · 93.6 GB used of 468.0 GB (20%)", root)
    }

    @Test
    fun `linux storage leaves out loop devices and lists network mounts separately`() {
        val specs = SystemSpecsParser.parse("Linux", linuxCommon)
        assertNull(specs.item(SpecKind.Storage, "loop0"))
        assertNull("An empty card reader is not a drive", specs.item(SpecKind.Storage, "sdb"))
        val efi = specs.item(SpecKind.Storage, "nvme0n1")!!.fields.find { it.label == "nvme0n1p1" }!!.value
        assertFalse("An empty label is not shown as \"\"", efi.contains("\"\""))
        val other = specs.item(SpecKind.Storage, "Other filesystems")!!
        assertEquals(listOf("/mnt/nas"), other.fields.map { it.label })
        assertEquals("1 drive · 476.9 GB", specs.section(SpecKind.Storage)!!.summary)
    }

    @Test
    fun `linux graphics names each card and adds nvidia-smi detail to its own card`() {
        val specs = SystemSpecsParser.parse("Linux", linuxCommon)
        val intel = specs.item(SpecKind.Gpu, "CometLake")!!
        assertEquals("i915", intel.fields.find { it.label == "Driver" }!!.value)
        val nvidia = specs.item(SpecKind.Gpu, "NVIDIA GeForce RTX 3090")!!
        assertEquals("24576 MiB", nvidia.fields.find { it.label == "Video memory" }!!.value)
        assertEquals("Gen 4 x16", nvidia.fields.find { it.label == "PCIe link" }!!.value)
        assertNull(intel.fields.find { it.label == "VBIOS" })
    }

    @Test
    fun `linux network shows the adapter's name and skips link-local addresses`() {
        val nic = SystemSpecsParser.parse("Linux", linuxCommon).item(SpecKind.Network, "eno1")!!
        assertEquals("1 Gb/s · up · 192.168.1.10/24", nic.summary)
        assertEquals("Ethernet Connection (11) I219-LM", nic.fields.find { it.label == "Adapter" }!!.value)
        assertNull(nic.fields.find { it.label == "IPv6" })
    }

    @Test
    fun `a refused sudo is reported in sudo's own words`() {
        val specs = SystemSpecsParser.parse("Linux", "sudo: a password is required\n$linuxCommon")
        assertEquals("sudo: a password is required", specs.sudoError)
        assertTrue(specs.wouldGainFromSudo)
    }

    @Test
    fun `missing tools are named instead of asking for root again`() {
        val specs = SystemSpecsParser.parse("Linux", "@PRIV\n@DIMM\n${SystemSpecsCommands.MISSING}\n@SMART\n${SystemSpecsCommands.MISSING}\n$linuxCommon")
        assertEquals(listOf(SpecNotice.ModulesToolMissing), specs.section(SpecKind.Memory)!!.notices)
        assertEquals(listOf(SpecNotice.DriveHealthToolMissing), specs.section(SpecKind.Storage)!!.notices)
        assertFalse(specs.wouldGainFromSudo)
    }

    @Test
    fun `busybox block devices without lsblk still list the drive`() {
        val busybox = """
            @OS
            Linux 5.15.0 armv7l
            @BLOCK
            NAME="mmcblk0" TYPE="disk" SIZE="31914983424" MODEL="" ROTA="0" RM="0"
            @MODEL
            Raspberry Pi 3 Model B Rev 1.2
            @CPUINFO
            processor	: 0
            model name	: ARMv7 Processor rev 4 (v7l)
            Features	: half thumb fastmult vfp
            Hardware	: BCM2835
            Revision	: a02082
        """.trimIndent()
        val specs = SystemSpecsParser.parse("Linux", busybox)
        assertEquals("Raspberry Pi 3 Model B Rev 1.2", specs.value(SpecKind.System, "Model"))
        assertEquals("BCM2835", specs.value(SpecKind.Cpu, "Hardware"))
        assertEquals("ARMv7 Processor rev 4 (v7l)", specs.value(SpecKind.Cpu, "model name"))
        assertEquals("29.7 GB · SD/eMMC", specs.item(SpecKind.Storage, "mmcblk0")!!.summary)
    }

    @Test
    fun `freebsd reads sysctl, kenv, geom, pciconf and ifconfig`() {
        val bsd = """
            @PRIV
            @DIMM
            ${SystemSpecsCommands.MISSING}
            @SMART
            ##DEV ada0
            SMART overall-health self-assessment test result: PASSED
              9 Power_On_Hours          0x0032   095   095   000    Old_age   Always       -       21234
            194 Temperature_Celsius     0x0022   067   052   000    Old_age   Always       -       33 (Min/Max 18/48)
            @OS
            FreeBSD 14.1-RELEASE amd64
            @HOSTNAME
            nas
            @RELEASE
            14.1-RELEASE-p5
            @NOW
            1793150000
            @SYSCTL
            hw.model	Intel(R) Xeon(R) E-2236 CPU @ 3.40GHz
            hw.machine_arch	amd64
            hw.ncpu	12
            kern.smp.cores	6
            hw.physmem	34225520640
            kern.boottime	{ sec = 1793140000, usec = 0 } Tue Oct 27 22:13:20 2026
            kern.vm_guest	none
            smbios.system.maker	Supermicro
            smbios.system.product	X11SCH-F
            @DMESG
            CPU: Intel(R) Xeon(R) E-2236 CPU @ 3.40GHz (3408.00-MHz K8-class CPU)
              Origin="GenuineIntel"  Id=0x906ea  Family=0x6  Model=0x9e  Stepping=10
              Features=0xbfebfbff<FPU,VME,DE>
              Features2=0x7ffafbff<SSE3,PCLMULQDQ>
            @SWAP
            /dev/ada0p3        2097152        0  2097152     0%
            @GEOM
            Geom name: ada0
            Providers:
            1. Name: ada0
               Mediasize: 500107862016 (466G)
               Sectorsize: 512
               descr: Samsung SSD 860 EVO 500GB
               ident: S3Z1NB0K123456X
               rotationrate: 0
            @DF
            Filesystem 1024-blocks Used Avail Capacity Mounted on
            zroot/ROOT/default 400000000 100000000 300000000 25% /
            @MOUNT
            zroot/ROOT/default / zfs rw 0 0
            @PCI
            vgapci0@pci0:0:2:0:	class=0x030000 rev=0x02 hdr=0x00 vendor=0x8086 device=0x3e96
                vendor     = 'Intel Corporation'
                device     = 'CoffeeLake-S GT2 [UHD Graphics P630]'
                class      = display
                subclass   = VGA
            em0@pci0:0:31:6:	class=0x020000 rev=0x10 hdr=0x00 vendor=0x8086 device=0x15bb
                vendor     = 'Intel Corporation'
                device     = 'Ethernet Connection (7) I219-LM'
                class      = network
                subclass   = ethernet
            @IFCONFIG
            em0: flags=1008843<UP,BROADCAST,RUNNING,SIMPLEX,MULTICAST,LOWER_UP> metric 0 mtu 1500
            ${'\t'}ether 00:25:90:aa:bb:cc
            ${'\t'}inet 192.168.1.20 netmask 0xffffff00 broadcast 192.168.1.255
            ${'\t'}media: Ethernet autoselect (1000baseT <full-duplex>)
            ${'\t'}status: active
            lo0: flags=1008049<UP,LOOPBACK,RUNNING,MULTICAST,LOWER_UP> metric 0 mtu 16384
            ${'\t'}inet 127.0.0.1 netmask 0xff000000
        """.trimIndent()
        val specs = SystemSpecsParser.parse("FreeBSD", bsd)
        assertEquals("FreeBSD 14.1-RELEASE-p5", specs.value(SpecKind.System, "Operating system"))
        assertEquals("Supermicro", specs.value(SpecKind.System, "Manufacturer"))
        assertEquals(10_000L, specs.uptimeSeconds)
        assertEquals("0x9e", specs.value(SpecKind.Cpu, "Model ID"))
        assertEquals("5 flags", specs.item(SpecKind.Cpu, "Flags")!!.summary)
        assertEquals(listOf(SpecNotice.ModulesToolMissing), specs.section(SpecKind.Memory)!!.notices)
        val drive = specs.item(SpecKind.Storage, "ada0")!!
        assertEquals("465.8 GB · SSD · PASSED", drive.summary)
        assertEquals("21234", drive.fields.find { it.label == "Power On Hours" }!!.value)
        assertEquals("zroot/ROOT/default · zfs · 95.4 GB used of 381.5 GB (25%)", specs.item(SpecKind.Storage, "Filesystems")!!.fields.single().value)
        assertEquals("CoffeeLake-S GT2 [UHD Graphics P630]", specs.section(SpecKind.Gpu)!!.items.single().title)
        val nic = specs.section(SpecKind.Network)!!.items.single()
        assertEquals("em0", nic.title)
        assertEquals("Ethernet Connection (7) I219-LM", nic.fields.find { it.label == "Adapter" }!!.value)
        assertEquals("1000baseT · active · 192.168.1.20", nic.summary)
    }

    @Test
    fun `macos reads system_profiler's nested groups`() {
        val mac = """
            @OS
            Darwin 23.5.0 arm64
            @HOSTNAME
            studio.local
            @SWVERS
            ProductName:		macOS
            ProductVersion:		14.5
            BuildVersion:		23F79
            @NOW
            1793150000
            @SYSCTL
            machdep.cpu.brand_string	Apple M1 Pro
            hw.physicalcpu	10
            hw.logicalcpu	10
            hw.perflevel0.name	Performance
            hw.perflevel0.physicalcpu	8
            hw.perflevel1.name	Efficiency
            hw.perflevel1.physicalcpu	2
            hw.l2cachesize	4194304
            hw.memsize	17179869184
            vm.swapusage	total = 1024.00M  used = 256.00M  free = 768.00M  (encrypted)
            kern.boottime	{ sec = 1793100000, usec = 0 } Mon Oct 27 2026
            @PROFILER
            Hardware:

                Hardware Overview:

                  Model Name: MacBook Pro
                  Model Identifier: MacBookPro18,3
                  Chip: Apple M1 Pro
                  Total Number of Cores: 10 (8 performance and 2 efficiency)
                  Memory: 16 GB
                  System Firmware Version: 10151.121.1

            Memory:

                  Memory: 16 GB
                  Type: LPDDR5
                  Manufacturer: Hynix

            Storage:

                Macintosh HD - Data:

                  Free: 300.12 GB (300,123,456,789 bytes)
                  Capacity: 494.38 GB (494,384,795,648 bytes)
                  Mount Point: /System/Volumes/Data
                  File System: APFS
                  Physical Drive:
                      Device Name: APPLE SSD AP0512R
                      Medium Type: SSD
                      S.M.A.R.T. Status: Verified

            Graphics/Displays:

                Apple M1 Pro:

                  Chipset Model: Apple M1 Pro
                  Total Number of Cores: 16
                  Displays:
                    Color LCD:
                      Resolution: 3024 x 1964 Retina
            @DF
            Filesystem 1024-blocks Used Available Capacity Mounted on
            /dev/disk3s5 482797652 188000000 294797652 39% /System/Volumes/Data
            @HWPORTS
            Hardware Port: Wi-Fi
            Device: en0
            Ethernet Address: aa:bb:cc:dd:ee:01
            @IFCONFIG
            en0: flags=8863<UP,BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST> mtu 1500
            ${'\t'}ether aa:bb:cc:dd:ee:01
            ${'\t'}inet 192.168.1.30 netmask 0xffffff00 broadcast 192.168.1.255
            ${'\t'}media: autoselect
            ${'\t'}status: active
            awdl0: flags=8943<UP,BROADCAST,RUNNING,PROMISC,SIMPLEX,MULTICAST> mtu 1500
            ${'\t'}ether aa:bb:cc:dd:ee:02
            ${'\t'}status: active
        """.trimIndent()
        val specs = SystemSpecsParser.parse("Darwin", mac)
        assertEquals("macOS 14.5 (23F79)", specs.value(SpecKind.System, "Operating system"))
        assertEquals("MacBookPro18,3", specs.value(SpecKind.System, "Model Identifier"))
        assertNull("The chip belongs to the processor section", specs.value(SpecKind.System, "Chip"))
        assertEquals(50_000L, specs.uptimeSeconds)
        assertEquals("8", specs.value(SpecKind.Cpu, "Performance cores"))
        assertEquals("4.0 MB", specs.value(SpecKind.Cpu, "L2 cache"))
        assertEquals("LPDDR5", specs.value(SpecKind.Memory, "Type"))
        val volume = specs.item(SpecKind.Storage, "Macintosh HD - Data")!!
        assertEquals("494.38 GB · APFS · 300.12 GB free", volume.summary)
        assertEquals("Verified", volume.fields.find { it.label == "Physical Drive · S.M.A.R.T. Status" }!!.value)
        val gpu = specs.section(SpecKind.Gpu)!!.items.single()
        assertEquals("3024 x 1964 Retina", gpu.fields.find { it.label == "Displays · Color LCD · Resolution" }!!.value)
        assertEquals(listOf("Wi-Fi (en0)"), specs.section(SpecKind.Network)!!.items.map { it.title })
    }

    @Test
    fun `windows reads cim records into the same sections`() {
        val win = """
            @OS
            ##ITEM
            Caption=Microsoft Windows 11 Pro
            Version=10.0.22631
            BuildNumber=22631
            OSArchitecture=64-bit
            CSName=GAMING-PC
            FreePhysicalMemory=8388608
            @CS
            ##ITEM
            Manufacturer=ASUS
            Model=System Product Name
            TotalPhysicalMemory=34359738368
            HypervisorPresent=False
            @CPU
            ##ITEM
            Name=AMD Ryzen 7 5800X 8-Core Processor
            NumberOfCores=8
            NumberOfLogicalProcessors=16
            MaxClockSpeed=3801
            L3CacheSize=32768
            VirtualizationFirmwareEnabled=True
            @MEMARRAY
            ##ITEM
            MemoryDevices=4
            @DIMM
            ##ITEM
            DeviceLocator=DIMM_A2
            BankLabel=BANK 1
            Capacity=17179869184
            SMBIOSMemoryType=26
            FormFactor=8
            Speed=3600
            ConfiguredClockSpeed=3600
            ConfiguredVoltage=1350
            Manufacturer=G Skill Intl
            PartNumber=F4-3600C16-16GVKC
            ##ITEM
            DeviceLocator=DIMM_B2
            Capacity=17179869184
            SMBIOSMemoryType=26
            @PDISK
            ##ITEM
            DeviceId=0
            FriendlyName=Samsung SSD 980 PRO 1TB
            MediaType=SSD
            BusType=NVMe
            Size=1000204886016
            HealthStatus=Healthy
            @RELIABILITY
            ##ITEM
            DeviceId=0
            Temperature=41
            Wear=2
            PowerOnHours=4321
            @VOLUME
            ##ITEM
            DeviceID=C:
            VolumeName=Windows
            FileSystem=NTFS
            Size=999000000000
            FreeSpace=499500000000
            @GPU
            ##ITEM
            Name=NVIDIA GeForce RTX 3080
            AdapterCompatibility=NVIDIA
            AdapterRAM=4293918720
            @NIC
            ##ITEM
            Index=3
            Name=Intel(R) Ethernet Controller I225-V
            NetConnectionID=Ethernet
            MACAddress=AA:BB:CC:DD:EE:FF
            Speed=2500000000
            NetConnectionStatus=2
            @NICCONF
            ##ITEM
            Index=3
            IPAddress=192.168.1.40, fe80::1234
            DHCPEnabled=True
        """.trimIndent()
        val specs = SystemSpecsParser.parse("Windows", win)
        assertEquals("Microsoft Windows 11 Pro", specs.value(SpecKind.System, "Operating system"))
        assertNull("Firmware placeholders are dropped", specs.value(SpecKind.System, "Model"))
        assertEquals("AMD Ryzen 7 5800X 8-Core Processor · 8 cores · 16 threads", specs.section(SpecKind.Cpu)!!.summary)
        assertEquals("32.0 MB", specs.value(SpecKind.Cpu, "L3 cache"))
        assertEquals("Enabled", specs.value(SpecKind.Cpu, "Virtualization in firmware"))
        assertEquals("32.0 GB · 2 of 4 slots used · DDR4 3600 MT/s", specs.section(SpecKind.Memory)!!.summary)
        val dimm = specs.item(SpecKind.Memory, "DIMM_A2")!!
        assertEquals("DIMM", dimm.fields.find { it.label == "Form factor" }!!.value)
        assertEquals("1.35 V", dimm.fields.find { it.label == "Voltage" }!!.value)
        val disk = specs.item(SpecKind.Storage, "Samsung")!!
        assertEquals("2%", disk.fields.find { it.label == "Wear" }!!.value)
        assertEquals("NTFS · 465.2 GB used of 930.4 GB (50%)", specs.item(SpecKind.Storage, "Volumes")!!.fields.single().value)
        assertEquals("4 GB or more", specs.section(SpecKind.Gpu)!!.items.single().fields.find { it.label == "Video memory" }!!.value)
        val nic = specs.item(SpecKind.Network, "Ethernet")!!
        assertEquals("2.5 Gb/s · Connected · 192.168.1.40", nic.summary)
    }

    @Test
    fun `each os family gets its own command`() {
        assertTrue(SystemSpecsCommands.forOs("Linux").contains("lscpu"))
        assertTrue("A board without a device tree must not print sh's error", SystemSpecsCommands.forOs("Linux").contains("[ -r /proc/device-tree/model ] &&"))
        assertTrue(SystemSpecsCommands.forOs("FreeBSD 14.1").contains("geom disk list"))
        assertTrue(SystemSpecsCommands.forOs("Darwin").contains("system_profiler"))
        assertTrue(SystemSpecsCommands.forOs("Windows").startsWith("powershell"))
        assertFalse("Opening the screen never tries sudo", SystemSpecsCommands.forOs("Linux").contains("sudo"))
        val withSudo = SystemSpecsCommands.forOs("Linux", sudoPassword = "s3cr3t-Pass")
        assertTrue(withSudo.contains("sudo -S -p ''"))
        assertFalse("The password goes on stdin, never in the command", withSudo.contains("s3cr3t-Pass"))
    }

    @Test
    fun `copied text lists every section, device and field`() {
        val text = SystemSpecsParser.parse("Linux", linuxCommon).asText { it.name }
        assertTrue(text.contains("Cpu — Intel(R) Core(TM) i5-10400"))
        assertTrue(text.contains("    Driver: i915"))
    }
}
