/// A host's hardware and software, read with each OS's own tools. Ported from `data/SystemSpecs.kt`.
library;

import 'dart:typed_data';

import 'host_tools.dart';
import 'kotlin_strings.dart';
import 'remote_commands.dart';
import 'remote_models.dart';
import 'remote_parsers.dart';

/// The sections of a host's system specs, in the order they are shown.
enum SpecKind { system, cpu, memory, storage, gpu, network }

/// Why part of a section is missing, so the screen can say so and offer what would fix it: a
/// [tool] the host lacks can be installed from the notice.
enum SpecNotice {
  /// Memory modules come from the firmware tables, which only root can read.
  modulesNeedRoot,

  /// Root could read them, but dmidecode is not installed.
  modulesToolMissing(HostTool.dmidecode),

  /// dmidecode ran and the firmware lists no modules (most virtual machines).
  noModulesReported,

  /// Drive health and wear come from SMART, which only root can read.
  driveHealthNeedsRoot,

  /// Root could read it, but smartctl is not installed.
  driveHealthToolMissing(HostTool.smartmontools),

  /// NVIDIA's driver is loaded, but nvidia-smi, which reports the card's memory and more, is not
  /// installed.
  gpuToolMissing(HostTool.nvidiaSmi);

  const SpecNotice([this.tool]);

  /// A tool the host lacks, which the notice offers to install.
  final HostTool? tool;
}

/// One labelled value, e.g. "L2 cache" → "1.5 MiB (6 instances)". An empty label shows the value
/// alone.
class SpecField {
  const SpecField(this.label, this.value);

  final String label;
  final String value;

  @override
  bool operator ==(Object other) =>
      other is SpecField && other.label == label && other.value == value;

  @override
  int get hashCode => Object.hash(label, value);

  @override
  String toString() => 'SpecField($label, $value)';
}

/// One device inside a section: a memory module, a drive, a graphics card, a network adapter.
class SpecItem {
  const SpecItem(this.title, [this.summary = '', this.fields = const []]);

  final String title;
  final String summary;
  final List<SpecField> fields;

  @override
  String toString() => 'SpecItem($title, $summary, $fields)';
}

/// A collapsible section: its own fields, then its devices, then why anything is missing.
class SpecSection {
  const SpecSection(
    this.kind, {
    this.summary = '',
    this.fields = const [],
    this.items = const [],
    this.notices = const [],
  });

  final SpecKind kind;
  final String summary;
  final List<SpecField> fields;
  final List<SpecItem> items;
  final List<SpecNotice> notices;
}

/// Everything the specs probe learned about one host.
class SystemSpecs {
  const SystemSpecs(this.sections, {this.uptimeSeconds, this.sudoError});

  final List<SpecSection> sections;

  /// Seconds since boot, when the host reports it; the screen formats it.
  final int? uptimeSeconds;

  /// sudo's own explanation when an elevated read was refused.
  final String? sudoError;

  SpecSection? section(SpecKind kind) => sections.where((s) => s.kind == kind).firstOrNull;

  /// True when reading again with sudo would fill in something that is missing now.
  bool get wouldGainFromSudo => sections.any(
    (s) => s.notices.any(
      (n) => n == SpecNotice.modulesNeedRoot || n == SpecNotice.driveHealthNeedsRoot,
    ),
  );

  /// Plain text for the clipboard, section by section, with [titles] naming each section.
  String asText(String Function(SpecKind) titles) {
    final out = StringBuffer();
    void appendField(SpecField field, String indent) {
      out.write(indent);
      if (field.label.isNotEmpty) out.write('${field.label}: ');
      out.write('${field.value}\n');
    }

    for (final section in sections) {
      if (out.isNotEmpty) out.write('\n');
      out.write(titles(section.kind));
      if (section.summary.isNotEmpty) out.write(' — ${section.summary}');
      out.write('\n');
      for (final f in section.fields) {
        appendField(f, '  ');
      }
      for (final item in section.items) {
        out.write('  ${item.title}');
        if (item.summary.isNotEmpty) out.write(' — ${item.summary}');
        out.write('\n');
        for (final f in item.fields) {
          appendField(f, '    ');
        }
      }
    }
    return out.toString();
  }

  SystemSpecs _copyWith({List<SpecSection>? sections, String? sudoError}) =>
      SystemSpecs(sections ?? this.sections, uptimeSeconds: uptimeSeconds, sudoError: sudoError);
}

// ── commands ─────────────────────────────────────────────────────────────────────────────────────
//
// The command that reads a host's specs, one per operating system family (see [normaliseOs]). Each
// prints `@SECTION` blocks for [parseSystemSpecs].
//
// Memory modules and drive health need root on Linux and the BSDs. As root they are read straight
// away; otherwise only when the user asks to read with sudo, so opening the screen never tries sudo
// behind the user's back (a failed sudo is logged, and can mail the administrator). macOS reports
// both without root, and Windows reports what the signed-in account may see.

/// The specs command for [os]. A non-null [sudoPassword] reads the root-only parts through sudo
/// (blank tries passwordless sudo).
String systemSpecsCommand(String os, {String? sudoPassword}) => switch (normaliseOs(os)) {
  'Windows' => _specsWindows,
  'Darwin' => _specsDarwin,
  'FreeBSD' => _specsBsd(sudoPassword),
  _ => _specsLinux(sudoPassword),
};

const specsMissing = '!MISSING';
const specsDeviceMarker = '##DEV ';

/// `printf key<TAB>value` for each sysctl that answers; unknown keys are skipped quietly.
String _sysctlFields(List<String> keys) =>
    'for k in ${keys.join(' ')}; do '
    r'''v=$(sysctl -n $k 2>/dev/null) && [ -n "$v" ] && printf '%s\t%s\n' $k "$v"; done; ''';

/// Runs [privileged] as root: directly when already root, through sudo when [sudoPassword] is given
/// (blank tries passwordless sudo), and not at all otherwise. It comes first so that a password on
/// stdin reaches sudo before any other command could read it.
String _elevated(String privileged, String? sudoPassword) => sudoPassword == null
    ? 'if [ "\$(id -u)" = 0 ]; then sh -c ${shellQuote(privileged)}; fi; '
    : 'if [ "\$(id -u)" = 0 ]; then sh -c ${shellQuote(privileged)}; else '
          '${sudoShWrap(privileged, sudoPassword)}; fi; ';

/// Root-only reads: memory modules from dmidecode, then SMART for each drive in [drives].
String _privileged(String drives) =>
    "${otHelper}echo '@PRIV'; "
    "echo '@DIMM'; if command -v dmidecode >/dev/null 2>&1; then ot 10 dmidecode -t 16,17 2>&1; "
    "else echo '$specsMissing'; fi; "
    "echo '@SMART'; if command -v smartctl >/dev/null 2>&1; then for d in $drives; do "
    'echo "$specsDeviceMarker\$d"; ot 10 smartctl -i -H -A /dev/\$d 2>&1; done; '
    "else echo '$specsMissing'; fi; true";

const _linuxDrives = r"$(ls /sys/block 2>/dev/null | grep -vE '^(loop|ram|zram|sr|fd|dm-|md|nbd)')";

String _specsLinux(String? sudoPassword) =>
    '${_elevated(_privileged(_linuxDrives), sudoPassword)}$otHelper'
    "echo '@OS'; uname -srm 2>/dev/null; "
    "echo '@HOSTNAME'; hostname 2>/dev/null || cat /proc/sys/kernel/hostname 2>/dev/null; "
    "echo '@RELEASE'; cat /etc/os-release 2>/dev/null; "
    "echo '@UPTIME'; cat /proc/uptime 2>/dev/null; "
    "echo '@VIRT'; systemd-detect-virt 2>/dev/null; "
    // Readable without root, except the serial numbers, which are left out.
    "echo '@DMI'; for f in sys_vendor product_name product_version product_family board_vendor board_name "
    r'board_version bios_vendor bios_version bios_date chassis_type; do [ -r /sys/class/dmi/id/$f ] && '
    r'''printf '%s\t%s\n' $f "$(cat /sys/class/dmi/id/$f 2>/dev/null)"; done; '''
    // Boards without DMI (Raspberry Pi and other ARM boards) name themselves in the device tree.
    r"""echo '@MODEL'; [ -r /proc/device-tree/model ] && tr -d '\000' < /proc/device-tree/model; echo; """
    "echo '@LSCPU'; LANG=C lscpu 2>/dev/null; "
    // The first processor's block, plus the board lines ARM prints once at the end.
    r"echo '@CPUINFO'; sed '/^$/q' /proc/cpuinfo 2>/dev/null; "
    "grep -E '^(Hardware|Revision|Model)[[:space:]]*:' /proc/cpuinfo 2>/dev/null | sort -u; "
    "echo '@CPUFREQ'; c=/sys/devices/system/cpu/cpu0/cpufreq; "
    'for f in scaling_driver scaling_governor cpuinfo_min_freq cpuinfo_max_freq; do '
    r'''[ -r $c/$f ] && printf '%s\t%s\n' $f "$(cat $c/$f)"; done; '''
    r'''printf 'scaling_cur_freq\t%s\n' "$(cat /sys/devices/system/cpu/cpu[0-9]*/cpufreq/scaling_cur_freq 2>/dev/null | tr '\n' ' ')"; '''
    "echo '@VULN'; grep -H . /sys/devices/system/cpu/vulnerabilities/* 2>/dev/null; "
    "echo '@MEMINFO'; cat /proc/meminfo 2>/dev/null; "
    "echo '@SWAPS'; tail -n +2 /proc/swaps 2>/dev/null; "
    // lsblk's key="value" pairs; older lsblk lacks some columns, and BusyBox has no lsblk, so
    // /sys/block stands in with the same pairs.
    "echo '@BLOCK'; lsblk -b -P -o NAME,PKNAME,TYPE,SIZE,MODEL,SERIAL,VENDOR,REV,TRAN,ROTA,RM,FSTYPE,LABEL,MOUNTPOINT,PHY-SEC,LOG-SEC 2>/dev/null || "
    'lsblk -b -P -o NAME,TYPE,SIZE,MODEL,ROTA,RM,FSTYPE,MOUNTPOINT 2>/dev/null || '
    r'''for b in /sys/block/*; do n=${b##*/}; printf 'NAME="%s" TYPE="disk" SIZE="%s" MODEL="%s" ROTA="%s" RM="%s"\n' '''
    r'$n "$(($(cat $b/size 2>/dev/null || echo 0) * 512))" "$(cat $b/device/model 2>/dev/null)" '
    r'"$(cat $b/queue/rotational 2>/dev/null)" "$(cat $b/removable 2>/dev/null)"; done; '
    "echo '@DF'; ot 5 df -PB1 2>/dev/null || ot 5 df -Pk 2>/dev/null | sed 's/^/KB1024 /'; "
    // Graphics: each DRM card's PCI ids, driver, video memory (AMD) and slot; lspci names them.
    r"echo '@DRM'; for c in /sys/class/drm/card[0-9]*; do case ${c##*/} in *-*) continue;; esac; d=$c/device; "
    r'''printf '%s\t%s\t%s\t%s\t%s\t%s\n' ${c##*/} "$(cat $d/vendor 2>/dev/null)" "$(cat $d/device 2>/dev/null)" '''
    r'"$(basename "$(readlink $d/driver 2>/dev/null)" 2>/dev/null)" "$(cat $d/mem_info_vram_total 2>/dev/null)" '
    r'"$(basename "$(readlink -f $d 2>/dev/null)" 2>/dev/null)"; done; '
    r"""echo '@LSPCI'; lspci -mm 2>/dev/null | grep -iE '"(VGA|3D|Display|Ethernet|Network)'; """
    "echo '@NVIDIA'; if command -v nvidia-smi >/dev/null 2>&1; then ot 10 nvidia-smi --query-gpu=pci.bus_id,name,driver_version,"
    'memory.total,vbios_version,pcie.link.gen.max,pcie.link.width.max,power.limit,temperature.gpu --format=csv,noheader 2>/dev/null; '
    "elif [ -e /proc/driver/nvidia/version ] && [ -e /dev/nvidiactl ]; then echo '$specsMissing'; fi; "
    // Physical interfaces only (those backed by a device); bridges, veths and tunnels are not hardware.
    r"echo '@NET'; for i in /sys/class/net/*; do [ -e $i/device ] || continue; "
    r'''printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' ${i##*/} "$(cat $i/address 2>/dev/null)" "$(cat $i/operstate 2>/dev/null)" '''
    r'"$(cat $i/speed 2>/dev/null)" "$(cat $i/mtu 2>/dev/null)" "$(basename "$(readlink $i/device/driver 2>/dev/null)" 2>/dev/null)" '
    r'"$(basename "$(readlink -f $i/device 2>/dev/null)" 2>/dev/null)" "$([ -d $i/wireless ] && echo wireless)"; done; '
    "echo '@ADDR'; ip -o addr show 2>/dev/null; true";

const _bsdSysctls = [
  'hw.model', 'hw.machine', 'hw.machine_arch', 'hw.ncpu', 'kern.smp.cpus', 'kern.smp.cores', //
  'kern.smp.threads_per_core', 'hw.clockrate', 'hw.cpuspeed', 'dev.cpu.0.freq',
  'dev.cpu.0.freq_levels', 'hw.physmem', 'hw.realmem', 'hw.usermem', 'hw.pagesize',
  'kern.boottime', 'kern.vm_guest', 'hw.vendor', 'hw.product', 'hw.version', 'kern.disks',
  'hw.disknames',
];

String _specsBsd(String? sudoPassword) =>
    '${_elevated(_privileged(r"$(sysctl -n kern.disks 2>/dev/null | tr ' ' '\n' | grep -vE '^(cd|md)')"), sudoPassword)}'
    "echo '@OS'; uname -srm 2>/dev/null; "
    "echo '@HOSTNAME'; hostname 2>/dev/null; "
    "echo '@RELEASE'; freebsd-version 2>/dev/null; "
    "echo '@NOW'; date +%s; "
    "echo '@SYSCTL'; ${_sysctlFields(_bsdSysctls)}"
    // FreeBSD keeps the SMBIOS identity in the kernel environment rather than in sysctl.
    'for k in smbios.system.maker smbios.system.product smbios.system.version smbios.planar.maker '
    'smbios.planar.product smbios.bios.vendor smbios.bios.version smbios.bios.reldate smbios.chassis.type; do '
    r'''v=$(kenv -q $k 2>/dev/null) && [ -n "$v" ] && printf '%s\t%s\n' $k "$v"; done; '''
    "echo '@DMESG'; grep -E '^(CPU:|  Origin|  Features|  AMD Features|  Structured Extended|  AMD Extended)' /var/run/dmesg.boot 2>/dev/null; "
    "echo '@SWAP'; { swapinfo -k 2>/dev/null || swapctl -lk 2>/dev/null; } | tail -n +2; "
    "echo '@GEOM'; geom disk list 2>/dev/null; "
    "echo '@DF'; df -Pk 2>/dev/null; "
    "echo '@MOUNT'; mount -p 2>/dev/null || mount 2>/dev/null; "
    "echo '@PCI'; pciconf -lv 2>/dev/null; "
    "echo '@IFCONFIG'; ifconfig -a 2>/dev/null; true";

const _darwinSysctls = [
  'machdep.cpu.brand_string', 'machdep.cpu.vendor', 'machdep.cpu.family', 'machdep.cpu.model', //
  'machdep.cpu.stepping', 'machdep.cpu.microcode_version', 'hw.physicalcpu', 'hw.logicalcpu',
  'hw.perflevel0.name', 'hw.perflevel0.physicalcpu', 'hw.perflevel1.name',
  'hw.perflevel1.physicalcpu', 'hw.cpufrequency', 'hw.cpufrequency_max', 'hw.l1icachesize',
  'hw.l1dcachesize', 'hw.l2cachesize', 'hw.l3cachesize', 'hw.memsize', 'hw.pagesize',
  'vm.swapusage', 'kern.boottime', 'kern.hv_vmm_present', 'machdep.cpu.features',
  'machdep.cpu.leaf7_features', 'machdep.cpu.extfeatures',
];

// system_profiler names the memory modules and drives (with SMART status) without root.
final String _specsDarwin =
    "echo '@OS'; uname -srm 2>/dev/null; "
    "echo '@HOSTNAME'; hostname 2>/dev/null; "
    "echo '@SWVERS'; sw_vers 2>/dev/null; "
    "echo '@NOW'; date +%s; "
    "echo '@SYSCTL'; ${_sysctlFields(_darwinSysctls)}"
    "echo '@PROFILER'; system_profiler SPHardwareDataType SPMemoryDataType SPStorageDataType SPDisplaysDataType 2>/dev/null; "
    // -P drops macOS's inode columns, which would otherwise end up in the mount point.
    "echo '@DF'; df -Pk 2>/dev/null; "
    "echo '@HWPORTS'; networksetup -listallhardwareports 2>/dev/null; "
    "echo '@IFCONFIG'; ifconfig -a 2>/dev/null; true";

// One record per object: `##ITEM` and then `Property=value` lines. Single quotes only, so the
// double-quoted -Command survives cmd.exe, OpenSSH's default shell on Windows.
const _specsWindows =
    r'''powershell -NoProfile -Command "$ErrorActionPreference='SilentlyContinue'; '''
    r'''function E($n,$o,$p){ Write-Output ('@'+$n); foreach($x in @($o)){ if($x -eq $null){continue}; '''
    r'''Write-Output '##ITEM'; foreach($k in $p){ $v=$x.$k; if($v -ne $null -and [string]$v -ne ''){ '''
    r"""Write-Output ($k+'='+(@($v) -join ', ')) } } } }; """
    "E 'OS' (Get-CimInstance Win32_OperatingSystem) 'Caption','Version','BuildNumber','OSArchitecture','InstallDate',"
    "'LastBootUpTime','CSName','FreePhysicalMemory'; "
    "E 'CS' (Get-CimInstance Win32_ComputerSystem) 'Manufacturer','Model','SystemFamily','SystemType',"
    "'NumberOfProcessors','NumberOfLogicalProcessors','TotalPhysicalMemory','HypervisorPresent','Domain'; "
    "E 'BIOS' (Get-CimInstance Win32_BIOS) 'Manufacturer','SMBIOSBIOSVersion','ReleaseDate'; "
    "E 'BOARD' (Get-CimInstance Win32_BaseBoard) 'Manufacturer','Product','Version'; "
    "E 'CPU' (Get-CimInstance Win32_Processor) 'Name','Manufacturer','Description','SocketDesignation',"
    "'NumberOfCores','NumberOfLogicalProcessors','MaxClockSpeed','CurrentClockSpeed','L2CacheSize','L3CacheSize',"
    "'AddressWidth','VirtualizationFirmwareEnabled','SecondLevelAddressTranslationExtensions'; "
    "E 'MEMARRAY' (Get-CimInstance Win32_PhysicalMemoryArray) 'MemoryDevices','MaxCapacityEx'; "
    "E 'DIMM' (Get-CimInstance Win32_PhysicalMemory) 'DeviceLocator','BankLabel','Capacity','SMBIOSMemoryType',"
    "'FormFactor','Speed','ConfiguredClockSpeed','ConfiguredVoltage','Manufacturer','PartNumber'; "
    "E 'PAGEFILE' (Get-CimInstance Win32_PageFileUsage) 'Name','AllocatedBaseSize','CurrentUsage','PeakUsage'; "
    "E 'PDISK' (Get-PhysicalDisk) 'DeviceId','FriendlyName','MediaType','BusType','Size','HealthStatus',"
    "'OperationalStatus','FirmwareVersion','SpindleSpeed'; "
    "E 'DISKDRIVE' (Get-CimInstance Win32_DiskDrive) 'Index','Model','Size','InterfaceType','MediaType','FirmwareRevision','Partitions'; "
    "E 'RELIABILITY' (Get-PhysicalDisk | Get-StorageReliabilityCounter) 'DeviceId','Temperature','Wear','PowerOnHours',"
    "'ReadErrorsTotal','WriteErrorsTotal'; "
    "E 'VOLUME' (Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3') 'DeviceID','VolumeName','FileSystem','Size','FreeSpace'; "
    "E 'GPU' (Get-CimInstance Win32_VideoController) 'Name','AdapterCompatibility','DriverVersion','DriverDate','AdapterRAM',"
    "'VideoProcessor','CurrentHorizontalResolution','CurrentVerticalResolution','CurrentRefreshRate'; "
    "E 'NIC' (Get-CimInstance Win32_NetworkAdapter -Filter 'PhysicalAdapter=True') 'Index','Name','NetConnectionID',"
    "'MACAddress','Speed','NetConnectionStatus','Manufacturer'; "
    "E 'NICCONF' (Get-CimInstance Win32_NetworkAdapterConfiguration -Filter 'IPEnabled=True') 'Index','IPAddress',"
    "'DefaultIPGateway','DNSServerSearchOrder','DHCPEnabled'\"";

// ── parsing ──────────────────────────────────────────────────────────────────────────────────────

/// Turns [systemSpecsCommand] output into [SystemSpecs].
SystemSpecs parseSystemSpecs(String os, String output) {
  final sections = splitSections(output);
  final specs = switch (normaliseOs(os)) {
    'Windows' => _windows(sections),
    'Darwin' => _darwin(sections),
    'FreeBSD' => _bsd(sections),
    _ => _linux(sections),
  };
  // Whatever sudo said before the first section is its refusal; the privileged part never ran.
  String? sudoError;
  if (!sections.containsKey('PRIV')) {
    for (final line in output.lines) {
      if (line.startsWith('@')) break;
      if (line.trim().isNotEmpty) sudoError = line.trim();
    }
  }
  return specs._copyWith(
    sections: specs.sections
        .where((s) => s.fields.isNotEmpty || s.items.isNotEmpty || s.notices.isNotEmpty)
        .toList(),
    sudoError: sudoError,
  );
}

// ── shared helpers ───────────────────────────────────────────────────────────────────────────────

final _decimal = RegExp(r'^[+-]?\d+$');

/// Kotlin's `toLongOrNull`: decimal digits only, no surrounding space, no `0x`.
int? _long(String? s) => s != null && _decimal.hasMatch(s) ? int.tryParse(s) : null;

double? _double(String? s) => s == null || s != s.trim() ? null : double.tryParse(s);

SpecField? _field(String label, String? value) {
  final v = value?.trim();
  return v == null || v.isEmpty ? null : SpecField(label, v);
}

/// Firmware fills unset identity strings with these; showing them would look like data.
const _placeholders = {
  'to be filled by o.e.m.', 'default string', 'not specified', 'not provided', //
  'system product name', 'system manufacturer', 'system version', 'o.e.m.', 'none', 'unknown',
  'not applicable', 'n/a', 'na', '0x00000000',
};

String? _real(String? value) {
  final v = value?.trim();
  return v == null || v.isEmpty || _placeholders.contains(v.toLowerCase()) ? null : v;
}

/// The present, real parts joined by [separator].
String? _joined(List<String?> parts, {String separator = ' '}) {
  final s = parts.map(_real).nonNulls.toSet().join(separator);
  return s.isEmpty ? null : s;
}

String _dotted(List<String?> parts) => parts.map(_real).nonNulls.join(' · ');

/// "key: value" lines (the first [separator] splits), ignoring lines without one.
List<(String, String)> _keyValues(String? text, [String separator = ':']) {
  final out = <(String, String)>[];
  for (final line in (text ?? '').lines) {
    final at = line.indexOf(separator);
    if (at <= 0) continue;
    final key = line.substring(0, at).trim();
    if (key.isNotEmpty) out.add((key, line.substring(at + 1).trim()));
  }
  return out;
}

Map<String, String> _tabValues(String? text) => {
  for (final line in (text ?? '').lines)
    if (line.indexOf('\t') > 0)
      line.substring(0, line.indexOf('\t')).trim(): line.substring(line.indexOf('\t') + 1).trim(),
};

Map<String, String> _toMap(List<(String, String)> pairs) => {for (final (k, v) in pairs) k: v};

String _substringAfterLast(String s, String delimiter) {
  final i = s.lastIndexOf(delimiter);
  return i < 0 ? s : s.substring(i + delimiter.length);
}

/// Kotlin's `trim(char)`: strips every [ch] from both ends.
String _trimChar(String s, String ch) {
  var start = 0;
  var end = s.length;
  while (start < end && s[start] == ch) {
    start++;
  }
  while (end > start && s[end - 1] == ch) {
    end--;
  }
  return s.substring(start, end);
}

final _whitespace = RegExp(r'\s+');

List<String> _words(String? s) => (s ?? '').trim().split(_whitespace);

String? _bytes(int? value) => value != null && value > 0 ? humanBytes(value) : null;

String _count(int n, String one, String many) => n == 1 ? '1 $one' : '$n $many';

String? _megahertz(int? mhz) => mhz == null || mhz <= 0
    ? null
    : mhz >= 1000
    ? '${(mhz / 1000).toStringAsFixed(2)} GHz'
    : '$mhz MHz';

/// Link speed in Mb/s as people say it: "1 Gb/s", "2.5 Gb/s", "100 Mb/s".
String? _linkSpeed(int? mbps) {
  if (mbps == null || mbps <= 0) return null;
  if (mbps < 1000) return '$mbps Mb/s';
  final gbps = mbps / 1000;
  return '${gbps % 1 == 0 ? gbps.toInt() : gbps} Gb/s';
}

/// `1234567` → `1,234,567`, as Kotlin's `"%,d".format(Locale.US, …)`.
String _grouped(int n) {
  final digits = n.abs().toString();
  final out = StringBuffer(n < 0 ? '-' : '');
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) out.write(',');
    out.write(digits[i]);
  }
  return out.toString();
}

String _usage(DiskUsage disk) =>
    '${humanBytes(disk.usedBytes)} used of ${humanBytes(disk.totalBytes)} (${_floatPercent(disk)}%)';

final _float = Float32List(1);

double _toFloat(double v) => (_float..[0] = v)[0];

/// The whole percent Kotlin shows: it divides in `Float`, so 19.9999999999% reads 20%, not 19%.
int _floatPercent(DiskUsage disk) => disk.totalBytes > 0
    ? _toFloat(
        _toFloat(_toFloat(disk.usedBytes.toDouble()) * 100) / _toFloat(disk.totalBytes.toDouble()),
      ).toInt()
    : 0;

const _pciVendors = {
  '0x10de': 'NVIDIA', '0x1002': 'AMD', '0x8086': 'Intel', '0x1a03': 'ASPEED', //
  '0x15ad': 'VMware', '0x1234': 'QEMU', '0x1af4': 'Red Hat (virtio)', '0x14e4': 'Broadcom',
  '0x10ec': 'Realtek', '0x106b': 'Apple', '0x1414': 'Microsoft', '0x80ee': 'VirtualBox',
};

const _chassis = {
  3: 'Desktop', 4: 'Low-profile desktop', 5: 'Pizza box', 6: 'Mini tower', 7: 'Tower', //
  8: 'Portable', 9: 'Laptop', 10: 'Notebook', 11: 'Handheld', 13: 'All-in-one',
  14: 'Sub-notebook', 17: 'Server chassis', 23: 'Rack-mount', 24: 'Sealed-case PC', 30: 'Tablet',
  31: 'Convertible', 32: 'Detachable', 34: 'Embedded PC', 35: 'Mini PC', 36: 'Stick PC',
};

/// dmidecode's memory array (type 16) and memory devices (type 17): the array gives the slot count
/// and maximum, each device one module or an empty slot. Shared by Linux and the BSDs.
(List<SpecField>, List<SpecItem>) dmidecodeMemory(String? text) {
  final arrayFields = <SpecField>[];
  final modules = <SpecItem>[];
  for (final block in (text ?? '').split(RegExp(r'\n\s*\n'))) {
    final lines = block.lines;
    final kind = lines.map((l) => l.trim()).toList();
    final values = <(String, String)>[];
    for (final line in lines) {
      if (!line.startsWith('\t') || line.startsWith('\t\t')) continue;
      final at = line.indexOf(':');
      if (at <= 0) continue;
      final k = line.substring(0, at).trim();
      final v = line.substring(at + 1).trim();
      if (v.isNotEmpty && !k.endsWith('Handle')) values.add((k, v));
    }
    final map = _toMap(values);
    if (kind.contains('Physical Memory Array')) {
      for (final (k, v) in values) {
        if (const {
          'Location',
          'Use',
          'Error Correction Type',
          'Maximum Capacity',
          'Number Of Devices',
        }.contains(k)) {
          arrayFields.add(SpecField(k, v));
        }
      }
    } else if (kind.contains('Memory Device')) {
      final size = map['Size'];
      final lower = size?.toLowerCase();
      final empty =
          size == null ||
          lower!.startsWith('no module') ||
          size == '0' ||
          lower.startsWith('not installed');
      final title =
          _joined([map['Locator'], map['Bank Locator']], separator: ' · ') ??
          'Module ${modules.length + 1}';
      modules.add(
        empty
            ? SpecItem(title, 'Empty')
            : SpecItem(
                title,
                _dotted([
                  size,
                  map['Type'],
                  map['Configured Memory Speed'] ?? map['Speed'],
                  map['Manufacturer'],
                ]),
                [
                  for (final (k, v) in values)
                    if (_real(v) != null) SpecField(k, v),
                ],
              ),
      );
    }
  }
  return (arrayFields, modules);
}

final _smartAttribute = RegExp(
  r'^\s*\d+\s+(\S+)\s+0x[0-9a-fA-F]+\s+\d+\s+\d+\s+\S+\s+\S+\s+\S+\s+(\S+)\s+(.+)$',
);

const _smartSkip = [
  'Local Time is', 'SMART support is', 'smartctl', 'Copyright', 'Device is', 'Read SMART', //
  'SMART Status',
];

final _letter = RegExp(r'^\p{L}', unicode: true);

/// One drive's `smartctl -i -H -A`: identity, the overall verdict, and each attribute's raw value.
Map<String, List<SpecField>> smartctl(String? text) {
  final byDevice = <String, List<SpecField>>{};
  for (final chunk in (text ?? '').split(specsDeviceMarker).skip(1)) {
    final chunkLines = chunk.lines;
    final device = chunkLines.first.trim();
    final fields = <SpecField>[];
    String? health;
    for (final line in chunkLines.skip(1)) {
      final row = _smartAttribute.firstMatch(line);
      if (line.contains('overall-health') || line.contains('Health Status:')) {
        health = _substringAfterLast(line, ':').trim();
      } else if (row != null) {
        final whenFailed = row.group(2)!;
        final failing = whenFailed != '-' ? ' (failing: $whenFailed)' : '';
        fields.add(SpecField(row.group(1)!.replaceAll('_', ' '), row.group(3)!.trim() + failing));
      } else {
        final at = line.indexOf(':');
        if (at > 0 && _letter.hasMatch(line)) {
          final key = line.substring(0, at).trim();
          final value = line.substring(at + 1).trim();
          if (value.isNotEmpty && !_smartSkip.any(key.startsWith)) {
            fields.add(SpecField(key, value));
          }
        }
      }
    }
    if (health != null || fields.isNotEmpty) {
      byDevice[device] = [if (health != null) SpecField('SMART health', health), ...fields];
    }
  }
  return byDevice;
}

/// A drive's smartctl fields that say something its other fields do not.
List<SpecField> _withSmart(List<SpecField> fields, List<SpecField>? smart) {
  final known = fields.map((f) => f.value.toLowerCase()).toSet();
  return [...fields, ...?smart?.where((f) => !known.contains(f.value.toLowerCase()))];
}

List<SpecNotice> _memoryNotices(bool privilegedRan, String? dimm, List<SpecItem> modules) {
  if (!privilegedRan) return const [SpecNotice.modulesNeedRoot];
  if ((dimm ?? '').trim() == specsMissing) return const [SpecNotice.modulesToolMissing];
  if (modules.isEmpty) return const [SpecNotice.noModulesReported];
  return const [];
}

List<SpecNotice> _driveNotices(bool privilegedRan, String? smart) {
  if (!privilegedRan) return const [SpecNotice.driveHealthNeedsRoot];
  if ((smart ?? '').trim() == specsMissing) return const [SpecNotice.driveHealthToolMissing];
  return const [];
}

String _memorySummary(int? total, List<SpecItem> modules, int? slots) {
  final used = modules.where((m) => m.summary != 'Empty').length;
  final slotText = modules.isEmpty ? null : '$used of ${slots ?? modules.length} slots used';
  final first = modules.where((m) => m.summary != 'Empty').firstOrNull;
  final kind = first?.summary.split(' · ').skip(1).take(2).join(' ');
  return _dotted([_bytes(total), slotText, kind]);
}

SpecItem? _flagsItem(String? flags) {
  final f = _real(flags);
  if (f == null) return null;
  final list = f.split(RegExp(r'[\s,]+')).where((x) => x.isNotEmpty).toList();
  return SpecItem('Flags', _count(list.length, 'flag', 'flags'), [SpecField('', list.join(' '))]);
}

const _virtualInterfaces = [
  'lo', 'bridge', 'tap', 'epair', 'pflog', 'pfsync', 'enc', 'gif', 'stf', 'utun', 'awdl', //
  'llw', 'anpi', 'ap',
];

final _allDigits = RegExp(r'^\d*$');
final _ifconfigHeader = RegExp(r'^([A-Za-z0-9_.]+): flags=');
final _ifconfigMtu = RegExp(r'mtu (\d+)');

/// ifconfig's interface blocks (FreeBSD, OpenBSD, macOS). [titles] names devices, e.g. en0 → Wi-Fi.
List<SpecItem> ifconfig(
  String? text, {
  Map<String, String> titles = const {},
  Map<String, String> adapters = const {},
}) {
  final items = <SpecItem>[];
  String? name;
  String? mtu;
  final lines = <(String, String)>[];
  void flush() {
    final n = name;
    if (n == null) return;
    final map = <String, List<String>>{};
    for (final (k, v) in lines) {
      map.putIfAbsent(k, () => []).add(v);
    }
    final ether = map['ether']?.firstOrNull ?? map['lladdr']?.firstOrNull;
    final virtual = _virtualInterfaces.any(
      (p) => n.startsWith(p) && _allDigits.hasMatch(n.substring(p.length)),
    );
    if (ether != null && !virtual && (titles.isEmpty || titles.containsKey(n))) {
      final ipv4 = [for (final a in map['inet'] ?? const <String>[]) a.substringBefore(' ')];
      final ipv6 = [
        for (final a in map['inet6'] ?? const <String>[])
          a.substringBefore(' ').substringBefore('%'),
      ].where((a) => !a.startsWith('fe80')).toList();
      final status = map['status']?.firstOrNull;
      final media = map['media']?.firstOrNull;
      items.add(
        SpecItem(
          titles[n] != null ? '${titles[n]} ($n)' : n,
          _dotted([
            media?.substringAfter('(', '').substringBefore(')').substringBefore(' '),
            status,
            ipv4.firstOrNull,
          ]),
          [
            _field('Adapter', adapters[n]),
            _field('MAC address', ether),
            _field('Status', status),
            _field('Media', media),
            _field('MTU', mtu),
            _field('IPv4', ipv4.join(', ')),
            _field('IPv6', ipv6.join(', ')),
          ].nonNulls.toList(),
        ),
      );
    }
    name = null;
    mtu = null;
    lines.clear();
  }

  for (final line in (text ?? '').lines) {
    final header = _ifconfigHeader.firstMatch(line);
    if (header != null) {
      flush();
      name = header.group(1);
      mtu = _ifconfigMtu.firstMatch(line)?.group(1);
    } else if (line.startsWith('\t') || line.startsWith(' ')) {
      final t = line.trim();
      lines.add((t.substringBefore(' ').removeSuffix(':'), t.substringAfter(' ', '').trim()));
    }
  }
  flush();
  return items;
}

// ── Linux ────────────────────────────────────────────────────────────────────────────────────────

SystemSpecs _linux(Map<String, String> s) {
  final privilegedRan = s.containsKey('PRIV');
  final uptime = _double(s['UPTIME']?.substringBefore(' '))?.toInt();
  final smart = smartctl(s['SMART']);
  final df = {for (final d in parseDisks(s['DF'] ?? '')) d.mount: d};
  final pci = _lspci(s['LSPCI']);
  return SystemSpecs([
    _linuxSystem(s),
    _linuxCpu(s),
    _linuxMemory(s, privilegedRan),
    _linuxStorage(s, smart, df, privilegedRan),
    _linuxGpu(s, pci),
    _linuxNetwork(s, pci),
  ], uptimeSeconds: uptime);
}

class _PciDevice {
  const _PciDevice(this.slot, this.kind, this.vendor, this.device);

  final String slot;
  final String kind;
  final String vendor;
  final String device;
}

final _lspciLine = RegExp(r'^(\S+)\s+"([^"]*)"\s+"([^"]*)"\s+"([^"]*)"');

/// `lspci -mm`: slot "class" "vendor" "device" …; a sysfs slot ends with the short one.
List<_PciDevice> _lspci(String? text) => [
  for (final line in (text ?? '').lines)
    if (_lspciLine.firstMatch(line) case final m?)
      _PciDevice(m.group(1)!, m.group(2)!, m.group(3)!, m.group(4)!),
];

_PciDevice? _pciAt(List<_PciDevice> pci, String? slot) =>
    slot == null || slot.isEmpty ? null : pci.where((p) => slot.endsWith(p.slot)).firstOrNull;

SpecSection _linuxSystem(Map<String, String> s) {
  final release = {for (final (k, v) in _keyValues(s['RELEASE'], '=')) k: _trimChar(v, '"')};
  final uname = _words(s['OS']);
  final dmi = _tabValues(s['DMI']);
  final virtRaw = s['VIRT']?.trim();
  final virt = virtRaw != null && virtRaw.isNotEmpty && virtRaw != 'none' ? virtRaw : null;
  final model = _real(s['MODEL']);
  final os = release['PRETTY_NAME'] ?? release['NAME'];
  final maker = _real(dmi['sys_vendor']);
  final product = _joined([dmi['product_name'], dmi['product_version']]);
  final biosDate = dmi['bios_date'];
  return SpecSection(
    SpecKind.system,
    summary: _dotted([
      model ?? _joined([maker, product]),
      os,
    ]),
    fields: [
      _field('Hostname', s['HOSTNAME']?.lines.firstOrNull),
      _field('Operating system', os),
      _field('Kernel', uname.getOrNull(1)),
      _field('Architecture', uname.getOrNull(2)),
      _field('Virtualization', virt),
      _field('Model', model),
      _field('Manufacturer', maker),
      _field('Product', product),
      _field('Family', _real(dmi['product_family'])),
      _field(
        'Motherboard',
        _joined([dmi['board_vendor'], dmi['board_name'], dmi['board_version']]),
      ),
      _field(
        'BIOS',
        _joined([dmi['bios_vendor'], dmi['bios_version'], biosDate == null ? null : '($biosDate)']),
      ),
      _field('Chassis', _chassis[_long(dmi['chassis_type'])]),
    ].nonNulls.toList(),
  );
}

SpecSection _linuxCpu(Map<String, String> s) {
  final fields = <SpecField>[];
  final vulnerabilities = <SpecField>[];
  String? flags;
  // lscpu nests related lines under a header with no value; Vulnerabilities is one of them.
  String? group;
  var groupIndent = -1;
  for (final line in (s['LSCPU'] ?? '').lines) {
    if (line.trim().isEmpty || !line.contains(':')) continue;
    final indent = line.length - line.trimLeft().length;
    if (group != null && indent <= groupIndent) group = null;
    final key = line.substringBefore(':').trim();
    final value = line.substringAfter(':').trim();
    if (value.isEmpty) {
      group = key;
      groupIndent = indent;
    } else if (key == 'Flags') {
      flags = value;
    } else if (key.startsWith('Vulnerability ')) {
      vulnerabilities.add(SpecField(key.removePrefix('Vulnerability '), value));
    } else if (group == 'Vulnerabilities') {
      vulnerabilities.add(SpecField(key, value));
    } else {
      fields.add(SpecField(key, value));
    }
  }
  // /proc/cpuinfo fills in what lscpu does not show (microcode, the Pi's board revision) or
  // everything, where there is no lscpu.
  final haveLscpu = fields.isNotEmpty;
  for (final (k, v) in _keyValues(s['CPUINFO'])) {
    if (k == 'flags' || k == 'Features') {
      flags ??= v;
    } else if (k == 'processor' || v.isEmpty) {
      continue;
    } else if (haveLscpu && !const {'microcode', 'Hardware', 'Revision', 'bugs'}.contains(k)) {
      continue;
    } else if (!fields.any((f) => f.label.toLowerCase() == k.toLowerCase())) {
      fields.add(SpecField(k, v));
    }
  }
  if (vulnerabilities.isEmpty) {
    for (final line in (s['VULN'] ?? '').lines) {
      final name = _substringAfterLast(line.substringBefore(':'), '/');
      final value = line.substringAfter(':').trim();
      if (name.isNotEmpty && value.isNotEmpty) {
        final spaced = name.replaceAll('_', ' ');
        vulnerabilities.add(SpecField(spaced[0].toUpperCase() + spaced.substring(1), value));
      }
    }
  }
  final freq = _tabValues(s['CPUFREQ']);
  final current = [
    for (final f in (freq['scaling_cur_freq'] ?? '').split(' '))
      if (_long(f) case final khz?) khz ~/ 1000,
  ].where((mhz) => mhz > 0).toList();
  String? now;
  if (current.isNotEmpty) {
    final min = current.reduce((a, b) => a < b ? a : b);
    final max = current.reduce((a, b) => a > b ? a : b);
    final average = (current.reduce((a, b) => a + b) / current.length).toInt();
    now =
        '${_megahertz(min)} – ${_megahertz(max)}, average ${_megahertz(average)} across '
        '${_count(current.length, 'core', 'cores')}';
  }
  final frequency = [
    _field('Driver', freq['scaling_driver']),
    _field('Governor', freq['scaling_governor']),
    _field('Minimum', _megahertz(_long(freq['cpuinfo_min_freq']).let((v) => v ~/ 1000))),
    _field('Maximum', _megahertz(_long(freq['cpuinfo_max_freq']).let((v) => v ~/ 1000))),
    _field('Now', now),
  ].nonNulls.toList();
  final byLabel = {for (final f in fields) f.label: f.value};
  final name = byLabel['Model name'] ?? byLabel['model name'] ?? byLabel['Hardware'];
  final sockets = _long(byLabel['Socket(s)']) ?? 1;
  final cores = _long(
    byLabel['Core(s) per socket'] ?? byLabel['Core(s) per cluster'],
  ).let((c) => c * sockets);
  final threads = _long(byLabel['CPU(s)']);
  final affected = vulnerabilities
      .where((v) => !v.value.toLowerCase().startsWith('not affected'))
      .length;
  return SpecSection(
    SpecKind.cpu,
    summary: _dotted([
      name,
      cores.let((c) => _count(c, 'core', 'cores')),
      threads.let((t) => _count(t, 'thread', 'threads')),
      _megahertz(_double(byLabel['CPU max MHz'])?.toInt()),
    ]),
    fields: fields,
    items: [
      if (frequency.isNotEmpty)
        SpecItem(
          'Frequency scaling',
          _dotted([freq['scaling_driver'], freq['scaling_governor']]),
          frequency,
        ),
      if (vulnerabilities.isNotEmpty)
        SpecItem(
          'Vulnerabilities',
          '$affected of ${vulnerabilities.length} need mitigation',
          vulnerabilities,
        ),
      ?_flagsItem(flags),
    ],
  );
}

SpecSection _linuxMemory(Map<String, String> s, bool privilegedRan) {
  final kb = {
    for (final (k, v) in _keyValues(s['MEMINFO']))
      k: _long(v.substringBefore(' ')).let((n) => n * 1024),
  };
  final total = kb['MemTotal'];
  final available = kb['MemAvailable'];
  final (array, modules) = dmidecodeMemory(privilegedRan ? s['DIMM'] : null);
  final hugeTotal = kb['HugePages_Total'].let((n) => n ~/ 1024);
  final swaps = <SpecItem>[];
  for (final line in (s['SWAPS'] ?? '').lines) {
    final t = _words(line);
    if (t.length < 5) continue;
    final size = _bytes(_long(t[2]).let((n) => n * 1024));
    swaps.add(
      SpecItem(
        t[0],
        _dotted([t[1], size]),
        [
          _field('Type', t[1]),
          _field('Size', size),
          _field('Used', humanBytes(_long(t[3]).let((n) => n * 1024) ?? 0)),
          _field('Priority', t[4]),
        ].nonNulls.toList(),
      ),
    );
  }
  return SpecSection(
    SpecKind.memory,
    summary: _memorySummary(
      total,
      modules,
      _long(array.where((f) => f.label == 'Number Of Devices').firstOrNull?.value),
    ),
    fields: [
      ...[
        _field('Total', _bytes(total)),
        _field('Available', _bytes(available)),
        _field('In use', _bytes(total != null && available != null ? total - available : null)),
        _field('Free', _bytes(kb['MemFree'])),
        _field('Buffers', _bytes(kb['Buffers'])),
        _field('Cached', _bytes(kb['Cached'])),
        _field('Shared', _bytes(kb['Shmem'])),
        _field('Kernel slab', _bytes(kb['Slab'])),
        _field('Swap total', _bytes(kb['SwapTotal'])),
        _field('Swap free', _bytes(kb['SwapFree'])),
        _field('Committed', _bytes(kb['Committed_AS'])),
        _field('Commit limit', _bytes(kb['CommitLimit'])),
        _field(
          'Huge pages',
          hugeTotal != null && hugeTotal > 0 ? '$hugeTotal × ${_bytes(kb['Hugepagesize'])}' : null,
        ),
      ].nonNulls,
      ...array,
    ],
    items: [...modules, ...swaps],
    notices: _memoryNotices(privilegedRan, s['DIMM'], modules),
  );
}

final _lsblkPair = RegExp(r'([A-Z][A-Z_:-]*)="((?:[^"\\]|\\.)*)"');
final _hexEscape = RegExp(r'\\x([0-9a-fA-F]{2})');

/// lsblk -P's KEY="value" pairs, with lsblk's \xHH escapes decoded and PHY-SEC spelt PHY_SEC.
List<Map<String, String>> _lsblk(String? text) => [
  for (final line in (text ?? '').lines)
    if ({
          for (final m in _lsblkPair.allMatches(line))
            m.group(1)!.replaceAll('-', '_'): m
                .group(2)!
                .replaceAllMapped(
                  _hexEscape,
                  (h) => String.fromCharCode(int.parse(h.group(1)!, radix: 16)),
                )
                .trim(),
        }
        case final pairs when pairs.containsKey('NAME'))
      pairs,
];

SpecSection _linuxStorage(
  Map<String, String> s,
  Map<String, List<SpecField>> smart,
  Map<String, DiskUsage> df,
  bool privilegedRan,
) {
  final nodes = _lsblk(s['BLOCK']);
  // A card reader or optical drive with nothing in it reports a size of 0.
  final drives = nodes
      .where(
        (n) =>
            const {'disk', 'rom'}.contains(n['TYPE']) &&
            !const ['loop', 'ram', 'zram'].any(n['NAME']!.startsWith) &&
            n['SIZE'] != '0',
      )
      .toList();
  // Without PKNAME (older lsblk), a partition is named after its drive: sda1, nvme0n1p1, mmcblk0p1.
  List<Map<String, String>> children(String parent) => nodes
      .where(
        (n) => n.containsKey('PKNAME')
            ? n['PKNAME'] == parent
            : n['TYPE'] == 'part' && n['NAME']!.startsWith(parent) && n['NAME'] != parent,
      )
      .toList();
  final shownMounts = <String>{};
  void describe(Map<String, String> node, int depth, List<SpecField> into) {
    final mount = node['MOUNTPOINT'] ?? '';
    if (mount.isNotEmpty) shownMounts.add(mount);
    final label = node['LABEL'];
    final type = node['TYPE'];
    into.add(
      SpecField(
        '${'  ' * depth}${node['NAME']!}',
        _dotted([
          _bytes(_long(node['SIZE'])),
          type != 'part' ? type : null,
          node['FSTYPE'],
          label != null && label.isNotEmpty ? '"$label"' : null,
          mount,
          df[mount] == null ? null : _usage(df[mount]!),
        ]),
      ),
    );
    for (final child in children(node['NAME']!)) {
      describe(child, depth + 1, into);
    }
  }

  final items = <SpecItem>[];
  for (final d in drives) {
    final name = d['NAME']!;
    final String? kind;
    if (d['TYPE'] == 'rom') {
      kind = 'Optical';
    } else if (name.startsWith('nvme') || d['TRAN'] == 'nvme') {
      kind = 'NVMe SSD';
    } else if (name.startsWith('mmcblk')) {
      kind = 'SD/eMMC';
    } else if (d['ROTA'] == '0') {
      kind = 'SSD';
    } else if (d['ROTA'] == '1') {
      kind = 'HDD';
    } else {
      kind = null;
    }
    final partitions = <SpecField>[];
    for (final child in children(name)) {
      describe(child, 0, partitions);
    }
    final model = _joined([d['VENDOR'], d['MODEL']]);
    final health = smart[name]?.where((f) => f.label == 'SMART health').firstOrNull?.value;
    final size = _long(d['SIZE']);
    final logSec = d['LOG_SEC'];
    final phySec = d['PHY_SEC'];
    items.add(
      SpecItem(
        [name, ?model].join(' — '),
        _dotted([_bytes(size), kind, d['TRAN']?.toUpperCase(), health]),
        _withSmart([
          ...[
            _field('Model', _real(d['MODEL'])),
            _field('Vendor', _real(d['VENDOR'])),
            _field('Serial number', _real(d['SERIAL'])),
            _field('Firmware', _real(d['REV'])),
            _field('Size', size == null ? null : '${humanBytes(size)} (${_grouped(size)} bytes)'),
            _field('Type', kind),
            _field('Interface', d['TRAN']?.toUpperCase()),
            _field('Removable', d['RM'] == '1' ? 'Yes' : null),
            _field(
              'Sector size',
              _joined([
                logSec == null ? null : '$logSec B logical',
                phySec == null ? null : '$phySec B physical',
              ], separator: ', '),
            ),
          ].nonNulls,
          ...partitions,
        ], smart[name]),
      ),
    );
  }
  // Mounts that are not on a local drive: network shares, ZFS datasets, and the like.
  final other = [
    for (final d in df.values)
      if (!shownMounts.contains(d.mount)) SpecField(d.mount, _dotted([d.filesystem, _usage(d)])),
  ];
  final total = drives
      .where((d) => d['TYPE'] == 'disk')
      .fold<int>(0, (sum, d) => sum + (_long(d['SIZE']) ?? 0));
  return SpecSection(
    SpecKind.storage,
    summary: _dotted([
      drives.isEmpty ? null : _count(drives.length, 'drive', 'drives'),
      _bytes(total),
    ]),
    items: [
      ...items,
      if (other.isNotEmpty)
        SpecItem('Other filesystems', _count(other.length, 'mount', 'mounts'), other),
    ],
    notices: drives.isEmpty ? const [] : _driveNotices(privilegedRan, s['SMART']),
  );
}

String _last7(String s) => s.length <= 7 ? s : s.substring(s.length - 7);

SpecSection _linuxGpu(Map<String, String> s, List<_PciDevice> pci) {
  final nvidia = <String, List<String>>{
    for (final line in (s['NVIDIA'] ?? '').lines)
      if (line.split(',').map((c) => c.trim()).toList() case final cols when cols.length >= 2)
        _last7(cols[0].toLowerCase()): cols,
  };
  final seen = <String>{};
  final items = <SpecItem>[];
  for (final line in (s['DRM'] ?? '').lines) {
    final t = line.split('\t');
    if (t.length < 6) continue;
    final vendorId = t[1];
    final deviceId = t[2];
    final driver = t[3];
    final vram = t[4];
    final slot = t[5];
    if (slot.isNotEmpty && !seen.add(slot)) continue;
    final device = _pciAt(pci, slot);
    final nv = nvidia[_last7(slot.toLowerCase())];
    final vendor = device?.vendor ?? _pciVendors[vendorId.toLowerCase()];
    final name = nv?.getOrNull(1) ?? device?.device ?? _joined([vendor, deviceId]) ?? driver;
    final memory = nv?.getOrNull(3) ?? _bytes(_long(vram));
    final gen = nv?.getOrNull(5);
    final width = nv?.getOrNull(6);
    final temperature = nv?.getOrNull(8);
    items.add(
      SpecItem(
        name,
        _dotted([memory, driver]),
        [
          _field('Vendor', vendor),
          _field('Device', device?.device),
          _field('Driver', driver),
          _field('Driver version', nv?.getOrNull(2)),
          _field('Video memory', memory),
          _field('VBIOS', nv?.getOrNull(4)),
          _field(
            'PCIe link',
            nv == null
                ? null
                : _joined([gen == null ? null : 'Gen $gen', width == null ? null : 'x$width']),
          ),
          _field('Power limit', nv?.getOrNull(7)),
          _field('Temperature', temperature == null ? null : '$temperature °C'),
          _field('PCI slot', slot),
        ].nonNulls.toList(),
      ),
    );
  }
  // Display controllers with no driver loaded have no DRM card, but lspci still lists them.
  final unbound = [
    for (final p in pci)
      if (const ['vga', '3d', 'display'].any(p.kind.toLowerCase().contains) &&
          !seen.any((slot) => slot.endsWith(p.slot)))
        SpecItem(p.device, _dotted([p.vendor, 'no driver loaded']), [
          SpecField('Vendor', p.vendor),
          SpecField('PCI slot', p.slot),
        ]),
  ];
  final nvidiaSmiMissing = (s['NVIDIA'] ?? '').trim() == specsMissing;
  return _gpuSection([...items, ...unbound], [if (nvidiaSmiMissing) SpecNotice.gpuToolMissing]);
}

SpecSection _linuxNetwork(Map<String, String> s, List<_PciDevice> pci) {
  final addresses = <String, List<(String, String)>>{};
  for (final line in (s['ADDR'] ?? '').lines) {
    final t = _words(line);
    if (t.length < 4 || (t[2] != 'inet' && t[2] != 'inet6')) continue;
    if (t[3].startsWith('fe80')) continue;
    addresses.putIfAbsent(t[1].substringBefore('@'), () => []).add((t[2], t[3]));
  }
  final items = <SpecItem>[];
  for (final line in (s['NET'] ?? '').lines) {
    // The last column (wireless) is empty for wired adapters, and a trimmed line drops it.
    final t = line.split('\t');
    if (t.length < 7) continue;
    final name = t[0];
    final adapter = _pciAt(pci, t[6]);
    final own = addresses[name] ?? const [];
    final ipv4 = [
      for (final (kind, a) in own)
        if (kind == 'inet') a,
    ];
    final ipv6 = [
      for (final (kind, a) in own)
        if (kind == 'inet6') a,
    ];
    final speed = _linkSpeed(_long(t[3]));
    items.add(
      SpecItem(
        name,
        _dotted([speed, t[2], ipv4.firstOrNull]),
        [
          _field('Adapter', adapter?.device),
          _field('Vendor', adapter?.vendor),
          _field('Kind', t.getOrNull(7) == 'wireless' ? 'Wireless' : null),
          _field('MAC address', t[1]),
          _field('State', t[2]),
          _field('Speed', speed),
          _field('MTU', t[4]),
          _field('Driver', t[5]),
          _field('IPv4', ipv4.join(', ')),
          _field('IPv6', ipv6.join(', ')),
          _field('PCI slot', adapter != null ? t[6] : null),
        ].nonNulls.toList(),
      ),
    );
  }
  return _networkSection(items);
}

/// The graphics section: its cards, named in the summary.
SpecSection _gpuSection(List<SpecItem> gpus, [List<SpecNotice> notices = const []]) => SpecSection(
  SpecKind.gpu,
  summary: gpus.map((g) => g.title).join(', '),
  items: gpus,
  notices: notices,
);

/// The network section: its adapters, counted in the summary.
SpecSection _networkSection(List<SpecItem> nics) => SpecSection(
  SpecKind.network,
  summary: nics.isEmpty ? '' : _count(nics.length, 'adapter', 'adapters'),
  items: nics,
);

/// A non-Linux host's sections, in the order every OS shows them.
SystemSpecs _specs(
  SpecSection system,
  SpecSection cpu,
  SpecSection memory,
  SpecSection storage,
  List<SpecItem> gpus,
  List<SpecItem> nics, {
  int? uptimeSeconds,
}) => SystemSpecs([
  system,
  cpu,
  memory,
  storage,
  _gpuSection(gpus),
  _networkSection(nics),
], uptimeSeconds: uptimeSeconds);

// ── FreeBSD / OpenBSD ────────────────────────────────────────────────────────────────────────────

final _bootSec = RegExp(r'sec = (\d+)');

int? _uptimeFrom(String? boottime, String? now) {
  final boot = _long(_bootSec.firstMatch(boottime ?? '')?.group(1));
  final n = _long(now?.trim());
  return boot != null && n != null && n > boot ? n - boot : null;
}

SystemSpecs _bsd(Map<String, String> s) {
  final privilegedRan = s.containsKey('PRIV');
  final sys = _tabValues(s['SYSCTL']);
  final uname = _words(s['OS']);
  final smart = smartctl(s['SMART']);
  final pci = _pciconf(s['PCI']);
  final biosDate = sys['smbios.bios.reldate'];

  final system = SpecSection(
    SpecKind.system,
    summary: _dotted([
      _joined([
        sys['smbios.system.maker'] ?? sys['hw.vendor'],
        sys['smbios.system.product'] ?? sys['hw.product'],
      ]),
      uname.firstOrNull,
    ]),
    fields: [
      _field('Hostname', s['HOSTNAME']),
      _field(
        'Operating system',
        _joined([uname.getOrNull(0), s['RELEASE']?.trim() ?? uname.getOrNull(1)]),
      ),
      _field('Architecture', sys['hw.machine_arch'] ?? uname.getOrNull(2)),
      _field('Virtualization', sys['kern.vm_guest'] != 'none' ? sys['kern.vm_guest'] : null),
      _field('Manufacturer', _real(sys['smbios.system.maker'] ?? sys['hw.vendor'])),
      _field(
        'Product',
        _joined([
          sys['smbios.system.product'] ?? sys['hw.product'],
          sys['smbios.system.version'] ?? sys['hw.version'],
        ]),
      ),
      _field('Motherboard', _joined([sys['smbios.planar.maker'], sys['smbios.planar.product']])),
      _field(
        'BIOS',
        _joined([
          sys['smbios.bios.vendor'],
          sys['smbios.bios.version'],
          biosDate == null ? null : '($biosDate)',
        ]),
      ),
    ].nonNulls.toList(),
  );

  final dmesg = (s['DMESG'] ?? '').lines;
  final origin = dmesg.where((l) => l.trim().startsWith('Origin')).firstOrNull ?? '';
  String? originValue(String key) => RegExp('$key="?([^"\\s]+)').firstMatch(origin)?.group(1);
  final flags = [
    for (final line in dmesg.where((l) => l.contains('Features')))
      ...?RegExp(r'<([^>]*)>').firstMatch(line)?.group(1)?.split(','),
  ].join(' ');
  final cpus = _long(sys['kern.smp.cpus'] ?? sys['hw.ncpu']);
  final cores = _long(sys['kern.smp.cores']);
  final levels = [
    for (final l in (sys['dev.cpu.0.freq_levels'] ?? '').split(' ')) ?_long(l.substringBefore('/')),
  ];
  final cpu = SpecSection(
    SpecKind.cpu,
    summary: _dotted([
      sys['hw.model'],
      cores.let((c) => _count(c, 'core', 'cores')),
      cpus.let((c) => _count(c, 'thread', 'threads')),
    ]),
    fields: [
      _field('Model', sys['hw.model']),
      _field('Architecture', sys['hw.machine_arch'] ?? sys['hw.machine']),
      _field('Vendor', originValue('Origin')),
      _field('Family', originValue('Family')),
      _field('Model ID', originValue('Model')),
      _field('Stepping', originValue('Stepping')),
      _field('Logical CPUs', cpus?.toString()),
      _field('Cores', cores?.toString()),
      _field('Threads per core', sys['kern.smp.threads_per_core']),
      _field('Clock', _megahertz(_long(sys['hw.clockrate'] ?? sys['hw.cpuspeed']))),
      _field('Current frequency', _megahertz(_long(sys['dev.cpu.0.freq']))),
      _field(
        'Frequency steps',
        levels.isEmpty
            ? null
            : '${_megahertz(levels.reduce((a, b) => a < b ? a : b))} – '
                  '${_megahertz(levels.reduce((a, b) => a > b ? a : b))} (${levels.length} steps)',
      ),
    ].nonNulls.toList(),
    items: [?_flagsItem(flags)],
  );

  final (array, modules) = dmidecodeMemory(privilegedRan ? s['DIMM'] : null);
  final physical = _long(sys['hw.physmem']);
  final swaps = <SpecItem>[];
  for (final line in (s['SWAP'] ?? '').lines) {
    final t = _words(line);
    if (t.length < 4) continue;
    final size = _bytes(_long(t[1]).let((n) => n * 1024));
    swaps.add(
      SpecItem(
        t[0],
        size ?? '',
        [
          _field('Size', size),
          _field('Used', humanBytes(_long(t[2]).let((n) => n * 1024) ?? 0)),
        ].nonNulls.toList(),
      ),
    );
  }
  final pageSize = sys['hw.pagesize'];
  final memory = SpecSection(
    SpecKind.memory,
    summary: _memorySummary(
      physical,
      modules,
      _long(array.where((f) => f.label == 'Number Of Devices').firstOrNull?.value),
    ),
    fields: [
      ...[
        _field('Physical', _bytes(physical)),
        _field('Installed', _bytes(_long(sys['hw.realmem']))),
        _field('Usable', _bytes(_long(sys['hw.usermem']))),
        _field('Page size', pageSize == null ? null : '$pageSize B'),
      ].nonNulls,
      ...array,
    ],
    items: [...modules, ...swaps],
    notices: _memoryNotices(privilegedRan, s['DIMM'], modules),
  );

  final df = parseDisks(s['DF'] ?? '', blockBytes: 1024);
  final fsTypes = _mountTypes(s['MOUNT']);
  final geoms = _geom(s['GEOM']);
  var diskNames = [for (final (name, _) in geoms) name];
  if (diskNames.isEmpty) {
    diskNames =
        (sys['kern.disks']?.split(' ') ??
                sys['hw.disknames']?.split(',').map((d) => d.substringBefore(':')).toList() ??
                const <String>[])
            .where((d) => d.isNotEmpty)
            .toList();
  }
  final drives = <SpecItem>[];
  for (final name in diskNames) {
    final g = geoms.where((e) => e.$1 == name).firstOrNull?.$2 ?? const <String, String>{};
    final size = _long(g['Mediasize']?.substringBefore(' '));
    final rotation = _long(g['rotationrate']);
    final String? kind;
    if (name.startsWith('nvd') || name.startsWith('nda')) {
      kind = 'NVMe SSD';
    } else if (rotation == 0) {
      kind = 'SSD';
    } else if (rotation != null && rotation > 1) {
      kind = 'HDD';
    } else {
      kind = null;
    }
    final health = smart[name]?.where((f) => f.label == 'SMART health').firstOrNull?.value;
    final descr = _real(g['descr']);
    final sector = g['Sectorsize'];
    final stripe = g['Stripesize'];
    drives.add(
      SpecItem(
        [name, ?descr].join(' — '),
        _dotted([_bytes(size), kind, health]),
        _withSmart(
          [
            _field('Model', descr),
            _field('Serial number', _real(g['ident'])),
            _field('Size', _bytes(size)),
            _field('Type', kind),
            _field('Rotation', rotation != null && rotation > 1 ? '$rotation rpm' : null),
            _field('Sector size', sector == null ? null : '$sector B'),
            _field('Stripe size', stripe != null && stripe != '0' ? '$stripe B' : null),
            _field('LUN ID', g['lunid']),
          ].nonNulls.toList(),
          smart[name],
        ),
      ),
    );
  }
  final filesystems = [
    for (final d in df) SpecField(d.mount, _dotted([d.filesystem, fsTypes[d.mount], _usage(d)])),
  ];
  final storage = SpecSection(
    SpecKind.storage,
    summary: _dotted([drives.isEmpty ? null : _count(drives.length, 'drive', 'drives')]),
    items: [
      ...drives,
      if (filesystems.isNotEmpty)
        SpecItem('Filesystems', _count(filesystems.length, 'mount', 'mounts'), filesystems),
    ],
    notices: drives.isEmpty ? const [] : _driveNotices(privilegedRan, s['SMART']),
  );

  final gpus = [
    for (final p in pci.where((p) => p.fields['class'] == 'display'))
      SpecItem(
        p.fields['device'] ?? p.driver,
        _dotted([p.fields['vendor'], p.driver]),
        [
          _field('Vendor', p.fields['vendor']),
          _field('Device', p.fields['device']),
          _field('Driver', p.driver),
          _field('PCI slot', p.slot),
        ].nonNulls.toList(),
      ),
  ];
  final adapters = {
    for (final p in pci.where((p) => p.fields['class'] == 'network'))
      p.driver: p.fields['device'] ?? '',
  };
  final nics = ifconfig(s['IFCONFIG'], adapters: adapters);
  return _specs(
    system,
    cpu,
    memory,
    storage,
    gpus,
    nics,
    uptimeSeconds: _uptimeFrom(sys['kern.boottime'], s['NOW']),
  );
}

/// `geom disk list`: one block per drive, "Geom name: ada0" then "   Key: value" lines.
List<(String, Map<String, String>)> _geom(String? text) => [
  for (final block in (text ?? '').split(RegExp(r'^Geom name: ', multiLine: true)).skip(1))
    (
      block.lines.first.trim(),
      {
        for (final (k, v) in _keyValues(block.lines.skip(1).join('\n')))
          k.removePrefix('1. ').trim(): v,
      },
    ),
];

final _mountOn = RegExp(r'^\S+ on (\S+) type (\S+)');

/// Mount point → filesystem type, from `mount -p` (FreeBSD) or `mount` (OpenBSD).
Map<String, String> _mountTypes(String? text) {
  final out = <String, String>{};
  for (final line in (text ?? '').lines) {
    final m = _mountOn.firstMatch(line);
    if (m != null) {
      out[m.group(1)!] = m.group(2)!;
      continue;
    }
    final t = _words(line);
    if (t.length >= 3) out[t[1]] = t[2];
  }
  return out;
}

class _PciConf {
  const _PciConf(this.driver, this.slot, this.fields);

  final String driver;
  final String slot;
  final Map<String, String> fields;
}

final _pciconfHeader = RegExp(r'^(\S+?)@(pci[0-9:]+):');

/// `pciconf -lv`: "em0@pci0:0:25:0: class=…" then indented "vendor = 'Intel Corporation'" lines.
List<_PciConf> _pciconf(String? text) => [
  for (final block in (text ?? '').split(RegExp(r'^(?=\S)', multiLine: true)))
    if (_pciconfHeader.firstMatch(block) case final header?)
      _PciConf(header.group(1)!, header.group(2)!, {
        for (final line in block.lines.skip(1))
          if (line.indexOf('=') > 0)
            line.substring(0, line.indexOf('=')).trim(): _trimChar(
              line.substring(line.indexOf('=') + 1).trim(),
              "'",
            ),
      }),
];

// ── macOS ────────────────────────────────────────────────────────────────────────────────────────

/// One line of system_profiler's indented text: a group when [value] is null.
class _ProfilerNode {
  _ProfilerNode(this.key, this.value, this.indent);

  final String key;
  final String? value;
  final int indent;
  final children = <_ProfilerNode>[];

  _ProfilerNode? child(String key) => children.where((c) => c.key == key).firstOrNull;

  List<SpecField> leaves() => [
    for (final c in children)
      if (c.value != null) SpecField(c.key, c.value!),
  ];

  /// Every leaf below, with nested groups' names in front of their fields.
  List<SpecField> allLeaves([String prefix = '']) => [
    for (final c in children)
      if (c.value != null)
        SpecField(prefix + c.key, c.value!)
      else
        ...c.allLeaves('$prefix${c.key} · '),
  ];
}

_ProfilerNode _profiler(String? text) {
  final root = _ProfilerNode('', null, -1);
  final stack = [root];
  for (final line in (text ?? '').lines) {
    if (line.trim().isEmpty) continue;
    final indent = line.length - line.trimLeft().length;
    final t = line.trim();
    final _ProfilerNode node;
    if (t.endsWith(':')) {
      node = _ProfilerNode(t.substring(0, t.length - 1), null, indent);
    } else if (t.contains(': ')) {
      node = _ProfilerNode(t.substringBefore(': '), t.substringAfter(': '), indent);
    } else {
      continue;
    }
    while (!identical(stack.last, root) && stack.last.indent >= indent) {
      stack.removeLast();
    }
    stack.last.children.add(node);
    if (node.value == null) stack.add(node);
  }
  return root;
}

const _cpuKeys = {
  'Chip', 'Processor Name', 'Processor Speed', 'Number of Processors', 'Total Number of Cores', //
  'L2 Cache (per Core)', 'L2 Cache', 'L3 Cache', 'Hyper-Threading Technology',
};

SystemSpecs _darwin(Map<String, String> s) {
  final sys = _tabValues(s['SYSCTL']);
  final sw = _toMap(_keyValues(s['SWVERS']));
  final uname = _words(s['OS']);
  final tree = _profiler(s['PROFILER']);
  final overview = tree.child('Hardware')?.child('Hardware Overview')?.leaves() ?? const [];
  final model = overview.where((f) => f.label == 'Model Name').firstOrNull?.value;
  final build = sw['BuildVersion'];

  final system = SpecSection(
    SpecKind.system,
    summary: _dotted([
      model,
      _joined([sw['ProductName'], sw['ProductVersion']]),
    ]),
    fields: [
      ...[
        _field('Hostname', s['HOSTNAME']),
        _field(
          'Operating system',
          _joined([sw['ProductName'], sw['ProductVersion'], build == null ? null : '($build)']),
        ),
        _field('Kernel', _joined([uname.getOrNull(0), uname.getOrNull(1)])),
        _field('Architecture', uname.getOrNull(2)),
        _field('Virtualization', sys['kern.hv_vmm_present'] == '1' ? 'Virtual machine' : null),
      ].nonNulls,
      ...overview.where((f) => !_cpuKeys.contains(f.label) && f.label != 'Memory'),
    ],
  );

  final chip = overview
      .where((f) => f.label == 'Chip' || f.label == 'Processor Name')
      .firstOrNull
      ?.value;
  final cores = _long(sys['hw.physicalcpu']);
  final threads = _long(sys['hw.logicalcpu']);
  final perf0 = sys['hw.perflevel0.name'];
  final perf1 = sys['hw.perflevel1.name'];
  final cpu = SpecSection(
    SpecKind.cpu,
    summary: _dotted([
      sys['machdep.cpu.brand_string'] ?? chip,
      cores.let((c) => _count(c, 'core', 'cores')),
      threads.let((t) => _count(t, 'thread', 'threads')),
    ]),
    fields: [
      ...[
        _field('Model', sys['machdep.cpu.brand_string']),
        _field('Vendor', sys['machdep.cpu.vendor']),
        _field('Family', sys['machdep.cpu.family']),
        _field('Model ID', sys['machdep.cpu.model']),
        _field('Stepping', sys['machdep.cpu.stepping']),
        _field('Microcode', sys['machdep.cpu.microcode_version']),
        _field('Cores', cores?.toString()),
        _field('Threads', threads?.toString()),
        _field(
          perf0 != null ? '$perf0 cores' : 'Performance cores',
          sys['hw.perflevel0.physicalcpu'],
        ),
        _field(
          perf1 != null ? '$perf1 cores' : 'Efficiency cores',
          sys['hw.perflevel1.physicalcpu'],
        ),
        _field('Frequency', _megahertz(_long(sys['hw.cpufrequency']).let((h) => h ~/ 1000000))),
        _field(
          'Maximum frequency',
          _megahertz(_long(sys['hw.cpufrequency_max']).let((h) => h ~/ 1000000)),
        ),
        _field('L1 instruction cache', _bytes(_long(sys['hw.l1icachesize']))),
        _field('L1 data cache', _bytes(_long(sys['hw.l1dcachesize']))),
        _field('L2 cache', _bytes(_long(sys['hw.l2cachesize']))),
        _field('L3 cache', _bytes(_long(sys['hw.l3cachesize']))),
      ].nonNulls,
      ...overview.where((f) => _cpuKeys.contains(f.label)),
    ],
    items: [
      ?_flagsItem(
        _joined([
          sys['machdep.cpu.features'],
          sys['machdep.cpu.leaf7_features'],
          sys['machdep.cpu.extfeatures'],
        ]),
      ),
    ],
  );

  final memoryNode = tree.child('Memory');
  final slots = memoryNode?.child('Memory Slots');
  final modules = [
    for (final bank in (slots ?? memoryNode)?.children ?? const <_ProfilerNode>[])
      if (bank.value == null) _darwinModule(bank),
  ];
  final total = _long(sys['hw.memsize']);
  final pageSize = sys['hw.pagesize'];
  final summary = _memorySummary(total, modules, null);
  final memory = SpecSection(
    SpecKind.memory,
    summary: summary.isEmpty ? _dotted([_bytes(total)]) : summary,
    fields: [
      ...[
        _field('Total', _bytes(total)),
        _field('Page size', pageSize == null ? null : '$pageSize B'),
        _field('Swap', sys['vm.swapusage']),
      ].nonNulls,
      ...(slots?.leaves() ?? memoryNode?.leaves() ?? const []),
    ],
    items: modules,
  );

  final volumes = <SpecItem>[];
  for (final volume in tree.child('Storage')?.children ?? const <_ProfilerNode>[]) {
    if (volume.value != null) continue;
    final f = volume.allLeaves();
    String? v(String k) => f.where((x) => x.label.endsWith(k)).firstOrNull?.value;
    final free = v('Free')?.substringBefore(' (');
    volumes.add(
      SpecItem(
        volume.key,
        _dotted([
          v('Capacity')?.substringBefore(' ('),
          v('File System'),
          free == null ? null : '$free free',
        ]),
        f,
      ),
    );
  }
  final storage = SpecSection(
    SpecKind.storage,
    summary: volumes.isEmpty ? '' : _count(volumes.length, 'volume', 'volumes'),
    items: volumes,
  );

  final gpus = <SpecItem>[];
  for (final g in tree.child('Graphics/Displays')?.children ?? const <_ProfilerNode>[]) {
    if (g.value != null) continue;
    final f = g.allLeaves();
    final vram = f
        .where((x) => x.label == 'VRAM (Dynamic, Max)' || x.label == 'VRAM (Total)')
        .firstOrNull
        ?.value;
    final cores = f.where((x) => x.label == 'Total Number of Cores').firstOrNull?.value;
    gpus.add(SpecItem(g.key, _dotted([vram, cores == null ? null : '$cores cores']), f));
  }

  final ports = <String, String>{};
  String? port;
  for (final (k, v) in _keyValues(s['HWPORTS'])) {
    if (k == 'Hardware Port') {
      port = v;
    } else if (k == 'Device' && port != null) {
      ports[v] = port;
    }
  }
  final nics = ifconfig(s['IFCONFIG'], titles: ports);
  return _specs(
    system,
    cpu,
    memory,
    storage,
    gpus,
    nics,
    uptimeSeconds: _uptimeFrom(sys['kern.boottime'], s['NOW']),
  );
}

SpecItem _darwinModule(_ProfilerNode bank) {
  final f = bank.leaves();
  String? v(String k) => f.where((x) => x.label == k).firstOrNull?.value;
  final empty = v('Size')?.toLowerCase().startsWith('empty') ?? false;
  return SpecItem(
    bank.key,
    empty ? 'Empty' : _dotted([v('Size'), v('Type'), v('Speed'), v('Manufacturer')]),
    empty ? const [] : f,
  );
}

// ── Windows ──────────────────────────────────────────────────────────────────────────────────────

List<Map<String, String>> _records(String? text) => [
  for (final block in (text ?? '').split('##ITEM'))
    if (_toMap(_keyValues(block, '=')) case final record when record.isNotEmpty) record,
];

const _memoryTypes = {
  20: 'DDR', 21: 'DDR2', 22: 'DDR2 FB-DIMM', 24: 'DDR3', 26: 'DDR4', 27: 'LPDDR', 28: 'LPDDR2', //
  29: 'LPDDR3', 30: 'LPDDR4', 34: 'DDR5', 35: 'LPDDR5',
};
const _formFactors = {8: 'DIMM', 12: 'SODIMM', 13: 'SRIMM', 9: 'RIMM', 11: 'Row of chips'};
const _nicStatus = {
  0: 'Disconnected',
  1: 'Connecting',
  2: 'Connected',
  7: 'Media disconnected',
  3: 'Disconnecting', //
};

String? _mts(String? v) => v == null ? null : '$v MT/s';
String? _mb(String? v) => v == null ? null : '$v MB';
String? _yesNo(String? v) => v == null ? null : (v == 'True' ? 'Yes' : 'No');

SystemSpecs _windows(Map<String, String> s) {
  final os = _records(s['OS']).firstOrNull ?? const {};
  final cs = _records(s['CS']).firstOrNull ?? const {};
  final bios = _records(s['BIOS']).firstOrNull ?? const {};
  final board = _records(s['BOARD']).firstOrNull ?? const {};
  final build = os['BuildNumber'];
  final biosDate = bios['ReleaseDate'];

  final system = SpecSection(
    SpecKind.system,
    summary: _dotted([
      _joined([cs['Manufacturer'], cs['Model']]),
      os['Caption'],
    ]),
    fields: [
      _field('Hostname', os['CSName']),
      _field('Operating system', os['Caption']),
      _field('Version', _joined([os['Version'], build == null ? null : '(build $build)'])),
      _field('Architecture', os['OSArchitecture']),
      _field('Manufacturer', _real(cs['Manufacturer'])),
      _field('Model', _real(cs['Model'])),
      _field('Family', _real(cs['SystemFamily'])),
      _field('System type', cs['SystemType']),
      _field('Motherboard', _joined([board['Manufacturer'], board['Product'], board['Version']])),
      _field(
        'BIOS',
        _joined([
          bios['Manufacturer'],
          bios['SMBIOSBIOSVersion'],
          biosDate == null ? null : '($biosDate)',
        ]),
      ),
      _field('Hypervisor present', cs['HypervisorPresent'] == 'True' ? 'Yes' : null),
      _field('Domain', cs['Domain']),
      _field('Installed', os['InstallDate']),
      _field('Last boot', os['LastBootUpTime']),
    ].nonNulls.toList(),
  );

  final processors = _records(s['CPU']);
  List<SpecField> cpuFields(Map<String, String> p) {
    final width = p['AddressWidth'];
    final virt = p['VirtualizationFirmwareEnabled'];
    return [
      _field('Model', p['Name']),
      _field('Manufacturer', p['Manufacturer']),
      _field('Description', p['Description']),
      _field('Socket', p['SocketDesignation']),
      _field('Cores', p['NumberOfCores']),
      _field('Logical processors', p['NumberOfLogicalProcessors']),
      _field('Maximum clock', _megahertz(_long(p['MaxClockSpeed']))),
      _field('Current clock', _megahertz(_long(p['CurrentClockSpeed']))),
      _field('L2 cache', _bytes(_long(p['L2CacheSize']).let((k) => k * 1024))),
      _field('L3 cache', _bytes(_long(p['L3CacheSize']).let((k) => k * 1024))),
      _field('Address width', width == null ? null : '$width-bit'),
      _field(
        'Virtualization in firmware',
        virt == null ? null : (virt == 'True' ? 'Enabled' : 'Disabled'),
      ),
      _field(
        'Second-level address translation',
        _yesNo(p['SecondLevelAddressTranslationExtensions']),
      ),
    ].nonNulls.toList();
  }

  final first = processors.firstOrNull ?? const {};
  final coreTotal = processors.fold<int>(0, (n, p) => n + (_long(p['NumberOfCores']) ?? 0));
  final threadTotal = processors.fold<int>(
    0,
    (n, p) => n + (_long(p['NumberOfLogicalProcessors']) ?? 0),
  );
  final cpu = SpecSection(
    SpecKind.cpu,
    summary: _dotted([
      first['Name'],
      coreTotal > 0 ? _count(coreTotal, 'core', 'cores') : null,
      threadTotal > 0 ? _count(threadTotal, 'thread', 'threads') : null,
    ]),
    fields: processors.length == 1 ? cpuFields(first) : const [],
    items: processors.length > 1
        ? [
            for (final (i, p) in processors.indexed)
              SpecItem(
                p['SocketDesignation'] ?? 'Processor ${i + 1}',
                p['Name'] ?? '',
                cpuFields(p),
              ),
          ]
        : const [],
  );

  final array = _records(s['MEMARRAY']).firstOrNull ?? const {};
  final modules = [for (final m in _records(s['DIMM'])) _windowsModule(m)];
  final pageFiles = [
    for (final p in _records(s['PAGEFILE']))
      SpecItem(
        p['Name'] ?? '',
        _mb(p['AllocatedBaseSize']) ?? '',
        [
          _field('Size', _mb(p['AllocatedBaseSize'])),
          _field('In use', _mb(p['CurrentUsage'])),
          _field('Peak', _mb(p['PeakUsage'])),
        ].nonNulls.toList(),
      ),
  ];
  final total = _long(cs['TotalPhysicalMemory']);
  final slotCount = _long(array['MemoryDevices']);
  final memory = SpecSection(
    SpecKind.memory,
    summary: _dotted([
      _bytes(total),
      modules.isEmpty ? null : '${modules.length} of ${slotCount ?? modules.length} slots used',
      modules.firstOrNull?.summary.split(' · ').skip(1).take(2).join(' '),
    ]),
    fields: [
      _field('Total', _bytes(total)),
      _field('Free', _bytes(_long(os['FreePhysicalMemory']).let((k) => k * 1024))),
      _field('Slots', slotCount?.toString()),
      _field('Maximum capacity', _bytes(_long(array['MaxCapacityEx']).let((k) => k * 1024))),
    ].nonNulls.toList(),
    items: [...modules, ...pageFiles],
  );

  final reliability = {for (final r in _records(s['RELIABILITY'])) r['DeviceId']: r};
  final physical = _records(s['PDISK']);
  final drives = physical.isNotEmpty
      ? [for (final d in physical) _windowsPhysicalDisk(d, reliability[d['DeviceId']] ?? const {})]
      : [
          for (final d in _records(s['DISKDRIVE']))
            SpecItem(
              d['Model'] ?? 'Disk ${d['Index']}',
              _dotted([_bytes(_long(d['Size'])), d['InterfaceType']]),
              [
                _field('Size', _bytes(_long(d['Size']))),
                _field('Interface', d['InterfaceType']),
                _field('Media', d['MediaType']),
                _field('Firmware', d['FirmwareRevision']),
                _field('Partitions', d['Partitions']),
              ].nonNulls.toList(),
            ),
        ];
  final volumes = <SpecField>[];
  for (final v in _records(s['VOLUME'])) {
    final size = _long(v['Size']);
    final free = _long(v['FreeSpace']);
    final name = v['VolumeName'];
    volumes.add(
      SpecField(
        _joined([v['DeviceID'], name == null ? null : '($name)']) ?? '',
        _dotted([
          v['FileSystem'],
          size != null && free != null
              ? _usage(
                  DiskUsage(
                    mount: v['DeviceID'] ?? '',
                    filesystem: v['FileSystem'] ?? '',
                    totalBytes: size,
                    usedBytes: size - free,
                  ),
                )
              : null,
        ]),
      ),
    );
  }
  final storage = SpecSection(
    SpecKind.storage,
    summary: _dotted([drives.isEmpty ? null : _count(drives.length, 'drive', 'drives')]),
    items: [
      ...drives,
      if (volumes.isNotEmpty)
        SpecItem('Volumes', _count(volumes.length, 'volume', 'volumes'), volumes),
    ],
  );

  final gpus = <SpecItem>[];
  for (final g in _records(s['GPU'])) {
    // AdapterRAM is a 32-bit value, so cards with 4 GB or more all report about 4 GB.
    final adapterRam = _long(g['AdapterRAM']);
    final ram = adapterRam == null
        ? null
        : adapterRam >= 4293918720
        ? '4 GB or more'
        : _bytes(adapterRam);
    final refresh = g['CurrentRefreshRate'];
    gpus.add(
      SpecItem(
        g['Name'] ?? '',
        _dotted([g['AdapterCompatibility'], ram]),
        [
          _field('Vendor', g['AdapterCompatibility']),
          _field('Processor', g['VideoProcessor']),
          _field('Video memory', ram),
          _field('Driver version', g['DriverVersion']),
          _field('Driver date', g['DriverDate']),
          _field(
            'Resolution',
            _joined([
              g['CurrentHorizontalResolution'],
              g['CurrentVerticalResolution'],
            ], separator: ' × '),
          ),
          _field('Refresh rate', refresh == null ? null : '$refresh Hz'),
        ].nonNulls.toList(),
      ),
    );
  }

  final config = {for (final c in _records(s['NICCONF'])) c['Index']: c};
  final nics = <SpecItem>[];
  for (final n in _records(s['NIC'])) {
    final c = config[n['Index']] ?? const {};
    final addresses = (c['IPAddress'] ?? '').split(', ').where((a) => a.isNotEmpty).toList();
    final speed = _linkSpeed(_long(n['Speed']).let((bps) => bps ~/ 1000000));
    final status = _nicStatus[_long(n['NetConnectionStatus'])];
    final ipv4 = addresses.where((a) => !a.contains(':')).toList();
    nics.add(
      SpecItem(
        n['NetConnectionID'] ?? n['Name'] ?? '',
        _dotted([speed, status, ipv4.firstOrNull]),
        [
          _field('Adapter', n['Name']),
          _field('Manufacturer', n['Manufacturer']),
          _field('MAC address', n['MACAddress']),
          _field('Status', status),
          _field('Speed', speed),
          _field('IPv4', ipv4.join(', ')),
          _field(
            'IPv6',
            addresses.where((a) => a.contains(':') && !a.startsWith('fe80')).join(', '),
          ),
          _field('Gateway', c['DefaultIPGateway']),
          _field('DNS servers', c['DNSServerSearchOrder']),
          _field('DHCP', _yesNo(c['DHCPEnabled'])),
        ].nonNulls.toList(),
      ),
    );
  }
  return _specs(system, cpu, memory, storage, gpus, nics);
}

SpecItem _windowsModule(Map<String, String> m) {
  final type = _memoryTypes[_long(m['SMBIOSMemoryType'])];
  final speed = _mts(m['ConfiguredClockSpeed'] ?? m['Speed']);
  final size = _bytes(_long(m['Capacity']));
  final millivolts = _long(m['ConfiguredVoltage']);
  return SpecItem(
    _joined([m['DeviceLocator'], m['BankLabel']], separator: ' · ') ?? 'Module',
    _dotted([size, type, speed, _real(m['Manufacturer'])]),
    [
      _field('Size', size),
      _field('Type', type),
      _field('Form factor', _formFactors[_long(m['FormFactor'])]),
      _field('Speed', _mts(m['Speed'])),
      _field('Configured speed', _mts(m['ConfiguredClockSpeed'])),
      _field(
        'Voltage',
        millivolts != null && millivolts > 0 ? '${(millivolts / 1000).toStringAsFixed(2)} V' : null,
      ),
      _field('Manufacturer', _real(m['Manufacturer'])),
      _field('Part number', _real(m['PartNumber'])),
    ].nonNulls.toList(),
  );
}

SpecItem _windowsPhysicalDisk(Map<String, String> d, Map<String, String> r) {
  final kind = d['MediaType'] != 'Unspecified' ? d['MediaType'] : null;
  final size = _bytes(_long(d['Size']));
  final spindle = _long(d['SpindleSpeed']);
  final temperature = r['Temperature'];
  final wear = r['Wear'];
  return SpecItem(
    d['FriendlyName'] ?? 'Disk ${d['DeviceId']}',
    _dotted([size, kind, d['BusType'], d['HealthStatus']]),
    [
      _field('Size', size),
      _field('Type', kind),
      _field('Interface', d['BusType']),
      _field('Health', d['HealthStatus']),
      _field('Status', d['OperationalStatus']),
      _field('Firmware', d['FirmwareVersion']),
      _field(
        'Rotation',
        spindle != null && spindle >= 1 && spindle <= 100000 ? '$spindle rpm' : null,
      ),
      _field('Temperature', temperature != null && temperature != '0' ? '$temperature °C' : null),
      _field('Wear', wear == null ? null : '$wear%'),
      _field('Power-on hours', r['PowerOnHours']),
      _field('Read errors', r['ReadErrorsTotal']),
      _field('Write errors', r['WriteErrorsTotal']),
    ].nonNulls.toList(),
  );
}

extension _Let on int? {
  /// Kotlin's `?.let { … }` for an int.
  T? let<T>(T Function(int) f) {
    final v = this;
    return v == null ? null : f(v);
  }
}
