/// The curated script presets the app seeds on demand, ported from `builtInFleetPresets` and
/// `homelabPresetScripts` in `ui/AppViewModel.kt`.
///
/// Each carries a stable [ScriptPreset.presetKey] that survives edits to its name or command. That
/// is what lets the preset toggles delete exactly what they seeded rather than matching on mutable
/// text — and what lets a backup tell a pristine preset (skip it, the toggle re-seeds it) from one
/// the user edited (keep it, the edit is theirs).
///
/// **The keys are historical facts about databases already on users' devices.** Changing one makes
/// an existing row stop being recognised as a preset, so it would survive a "disable" that was meant
/// to remove it. See also `legacy_presets.dart`, which back-stamps these keys onto rows seeded
/// before the column existed.
library;

class ScriptPreset {
  const ScriptPreset({
    required this.presetKey,
    required this.emoji,
    required this.name,
    required this.command,
    required this.color,
    required this.category,
    this.sortOrder = 0,
    this.availableForQuick = true,
    this.availableForFleet = false,
  });

  final String presetKey;

  /// The short badge shown on the card — three letters rather than a pictograph, so it stays legible
  /// at the size these are rendered.
  final String emoji;

  final String name;
  final String command;
  final String color;
  final String category;
  final int sortOrder;
  final bool availableForQuick;
  final bool availableForFleet;
}

/// The `app_settings` key holding whether a preset family is enabled.
const fleetPresetsSetting = 'fleet_presets';
const homelabPresetsSetting = 'homelab_presets';

/// Broadcast commands offered on the Fleet screen.
///
/// Every one falls through to a Windows PowerShell equivalent, because a fleet is rarely all one
/// operating system and a command that simply fails on a third of the hosts is not a useful preset.
const kFleetPresets = <ScriptPreset>[
  ScriptPreset(
    presetKey: 'fleet.cpu',
    emoji: 'CPU',
    name: 'CPU/RAM',
    command:
        'uptime 2>/dev/null || powershell -NoProfile -Command "(Get-CimInstance Win32_OperatingSystem).LastBootUpTime"; '
        'free -h 2>/dev/null || vm_stat 2>/dev/null || powershell -NoProfile -Command '
        '"Get-CimInstance Win32_OperatingSystem | ForEach-Object { \'TotalMB=\' + [int](\$_.TotalVisibleMemorySize/1024) + \' FreeMB=\' + [int](\$_.FreePhysicalMemory/1024) }"',
    color: 'cyan',
    category: 'Fleet',
    sortOrder: 0,
    availableForQuick: false,
    availableForFleet: true,
  ),
  ScriptPreset(
    presetKey: 'fleet.disk',
    emoji: 'DSK',
    name: 'Disk',
    command: 'df -h 2>/dev/null | head -6 || powershell -NoProfile -Command '
        '"Get-CimInstance Win32_LogicalDisk -Filter \'DriveType=3\' | Select-Object DeviceID,Size,FreeSpace"',
    color: 'cyan',
    category: 'Fleet',
    sortOrder: 1,
    availableForQuick: false,
    availableForFleet: true,
  ),
  ScriptPreset(
    presetKey: 'fleet.processes',
    emoji: 'PRC',
    name: 'Processes',
    command: 'ps aux 2>/dev/null | sort -k3 -nr | head -8 || '
        'ps -axo pid,user,pcpu,pmem,comm 2>/dev/null | sort -k3 -nr | head -8 || '
        'powershell -NoProfile -Command "Get-Process | Sort-Object CPU -Descending | Select-Object -First 8 Id,ProcessName,CPU,WorkingSet"',
    color: 'cyan',
    category: 'Fleet',
    sortOrder: 2,
    availableForQuick: false,
    availableForFleet: true,
  ),
  ScriptPreset(
    presetKey: 'fleet.services',
    emoji: 'SVC',
    name: 'Failed services',
    command: 'systemctl --failed 2>/dev/null || rc-status -c 2>/dev/null || '
        'powershell -NoProfile -Command "Get-Service | Where-Object Status -eq Stopped | Select-Object -First 12 Name,Status"',
    color: 'cyan',
    category: 'Fleet',
    sortOrder: 3,
    availableForQuick: false,
    availableForFleet: true,
  ),
  ScriptPreset(
    presetKey: 'fleet.syslog',
    emoji: 'LOG',
    name: 'Syslog errors',
    command: 'journalctl -p err -n 8 2>/dev/null || '
        "logread 2>/dev/null | grep -iE 'error|fail|critical' | tail -8 || "
        "grep -iE 'error|fail|critical' /var/log/syslog /var/log/messages 2>/dev/null | tail -8 || "
        'powershell -NoProfile -Command "Get-WinEvent -FilterHashtable @{LogName=\'System\'; Level=2} -MaxEvents 8 | Select-Object TimeCreated,ProviderName,Message"',
    color: 'cyan',
    category: 'Fleet',
    sortOrder: 4,
    availableForQuick: false,
    availableForFleet: true,
  ),
  ScriptPreset(
    presetKey: 'fleet.containers',
    emoji: 'CTR',
    name: 'Containers',
    command: r'docker ps --format "table {{.Names}}\t{{.Status}}" 2>/dev/null || '
        r'podman ps --format "table {{.Names}}\t{{.Status}}"',
    color: 'cyan',
    category: 'Fleet',
    sortOrder: 5,
    availableForQuick: false,
    availableForFleet: true,
  ),
  ScriptPreset(
    presetKey: 'fleet.ports',
    emoji: 'NET',
    name: 'Listening ports',
    command: 'ss -tlnp 2>/dev/null | grep LISTEN || netstat -tlnp 2>/dev/null | grep LISTEN || '
        'netstat -an 2>/dev/null | grep LISTEN || '
        'powershell -NoProfile -Command "Get-NetTCPConnection -State Listen | Select-Object -First 25 LocalAddress,LocalPort,OwningProcess"',
    color: 'cyan',
    category: 'Fleet',
    sortOrder: 6,
    availableForQuick: false,
    availableForFleet: true,
  ),
  ScriptPreset(
    presetKey: 'fleet.kernel',
    emoji: 'KRN',
    name: 'Kernel',
    command: 'uname -sr 2>/dev/null || '
        'powershell -NoProfile -Command "[Environment]::OSVersion.VersionString"',
    color: 'cyan',
    category: 'Fleet',
    sortOrder: 7,
    availableForQuick: false,
    availableForFleet: true,
  ),
];

/// Quick scripts for common homelab platforms.
///
/// Categorised by the platform they need (Proxmox, CasaOS, Home Assistant), which is what lets the
/// Quick Scripts filter hide the ones a given host cannot run — a `qm list` button on a host with no
/// Proxmox is noise.
const kHomelabPresets = <ScriptPreset>[
  ScriptPreset(
    presetKey: 'homelab.pve_vms',
    emoji: 'PVE',
    name: 'PVE: list VMs',
    command: 'qm list',
    color: 'orange',
    category: 'Proxmox',
  ),
  ScriptPreset(
    presetKey: 'homelab.pve_containers',
    emoji: 'PCT',
    name: 'PVE: list containers',
    command: 'pct list',
    color: 'orange',
    category: 'Proxmox',
  ),
  ScriptPreset(
    presetKey: 'homelab.pve_cluster',
    emoji: 'CLS',
    name: 'PVE: cluster status',
    command: "pvecm status 2>/dev/null || echo 'standalone node'",
    color: 'orange',
    category: 'Proxmox',
  ),
  ScriptPreset(
    presetKey: 'homelab.pve_storage',
    emoji: 'STO',
    name: 'PVE: storage status',
    command: 'pvesm status',
    color: 'orange',
    category: 'Proxmox',
  ),
  ScriptPreset(
    presetKey: 'homelab.pve_start_vm',
    emoji: 'RUN',
    // The literal `100` is a placeholder the user edits — a VM id cannot be guessed, and a preset
    // that refuses to run until edited teaches less than one that shows the shape of the command.
    name: 'PVE: start VM <id>',
    command: 'qm start 100',
    color: 'orange',
    category: 'Proxmox',
  ),
  ScriptPreset(
    presetKey: 'homelab.pve_stop_vm',
    emoji: 'STP',
    name: 'PVE: stop VM <id>',
    command: 'qm stop 100',
    color: 'orange',
    category: 'Proxmox',
  ),
  ScriptPreset(
    presetKey: 'homelab.casaos_status',
    emoji: 'CAS',
    name: 'CasaOS: status',
    command: "systemctl status 'casaos*' --no-pager 2>&1 | head -40",
    color: 'green',
    category: 'CasaOS',
  ),
  ScriptPreset(
    presetKey: 'homelab.casaos_restart',
    emoji: 'RST',
    name: 'CasaOS: restart',
    command: "sudo systemctl restart 'casaos*'",
    color: 'green',
    category: 'CasaOS',
  ),
  ScriptPreset(
    presetKey: 'homelab.casaos_version',
    emoji: 'VER',
    name: 'CasaOS: version',
    command: 'casaos -v 2>/dev/null || cat /etc/casaos/* 2>/dev/null | head',
    color: 'green',
    category: 'CasaOS',
  ),
  ScriptPreset(
    presetKey: 'homelab.ha_info',
    emoji: 'HA',
    name: 'HA: info',
    command: 'ha info 2>/dev/null || docker ps --filter name=homeassistant',
    color: 'cyan',
    category: 'Home Assistant',
  ),
  ScriptPreset(
    presetKey: 'homelab.ha_core_logs',
    emoji: 'LOG',
    name: 'HA: core logs',
    command: 'ha core logs 2>/dev/null || docker logs --tail 100 homeassistant 2>&1',
    color: 'cyan',
    category: 'Home Assistant',
  ),
  ScriptPreset(
    presetKey: 'homelab.ha_restart_core',
    emoji: 'RST',
    name: 'HA: restart core',
    command: 'ha core restart 2>/dev/null || docker restart homeassistant',
    color: 'cyan',
    category: 'Home Assistant',
  ),
  ScriptPreset(
    presetKey: 'homelab.ha_supervisor_logs',
    emoji: 'SUP',
    name: 'HA: supervisor logs',
    command: 'ha supervisor logs 2>/dev/null | tail -100',
    color: 'cyan',
    category: 'Home Assistant',
  ),
  ScriptPreset(
    presetKey: 'homelab.temperature',
    emoji: 'TMP',
    name: 'Temperature',
    // Reads every thermal zone and reports the hottest, falling back to the Raspberry Pi's own
    // `vcgencmd`. A host with no sensor says so rather than printing nothing, which would be
    // indistinguishable from a failed command.
    command: r'''if [ "$(uname -s 2>/dev/null)" = Linux ]; then max=""; for f in /sys/class/thermal/thermal_zone*/temp; do [ -r "$f" ] || continue; v=$(cat "$f" 2>/dev/null); case "$v" in ''|*[!0-9]*) continue;; esac; [ -z "$max" ] || [ "$v" -gt "$max" ] && max="$v"; done; if [ -n "$max" ]; then awk -v t="$max" 'BEGIN { printf "CPU %.1f°C\n", t / 1000 }'; elif command -v vcgencmd >/dev/null 2>&1; then vcgencmd measure_temp; else echo "No thermal sensor exposed"; fi; else echo "Temperature preset supports Linux hosts"; fi''',
    color: 'red',
    category: 'Linux',
  ),
  ScriptPreset(
    presetKey: 'homelab.updates',
    emoji: 'UPD',
    name: 'Updates available',
    command: 'apt list --upgradable 2>/dev/null | tail -n +2 || '
        '(command -v dnf >/dev/null && dnf check-update)',
    color: 'amber',
    category: 'Homelab',
  ),
  ScriptPreset(
    presetKey: 'homelab.reboot_required',
    emoji: 'RBT',
    name: 'Reboot required?',
    command: "test -f /var/run/reboot-required && echo 'reboot required' || echo 'no reboot needed'",
    color: 'amber',
    category: 'Homelab',
  ),
  ScriptPreset(
    presetKey: 'homelab.top_cpu',
    emoji: 'CPU',
    name: 'Top 10 by CPU',
    command: 'ps aux --sort=-%cpu | head -11',
    color: 'purple',
    category: 'Homelab',
  ),
  ScriptPreset(
    presetKey: 'homelab.docker_stats',
    emoji: 'CTR',
    name: 'Docker stats',
    command: 'docker stats --no-stream 2>/dev/null || podman stats --no-stream',
    color: 'purple',
    category: 'Homelab',
  ),
  ScriptPreset(
    presetKey: 'homelab.disk_usage',
    emoji: 'DSK',
    name: 'Disk usage',
    command: "df -h | grep -vE 'tmpfs|udev'",
    color: 'purple',
    category: 'Homelab',
  ),
];

/// Every preset the app knows about, for identifying a pristine seeded row.
const kAllScriptPresets = [...kFleetPresets, ...kHomelabPresets];

/// True when [command] and [name] still match what the preset seeded.
///
/// A pristine row is the app's, so a backup skips it and the toggle re-seeds it. Once the user edits
/// it, it is effectively theirs and must survive both.
bool isPristinePreset(ScriptPreset preset, String name, String command) =>
    preset.name == name && preset.command == command;
