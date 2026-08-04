/// Ported from `data/RemoteParsers.kt`'s `RemoteCommands` object.
///
/// **Partial port.** Only [normaliseOs] is here so far, because `remote_parsers.dart` dispatches on
/// it. The ~940 lines of shell command strings land with the screens that issue them
/// (MIGRATION.md §3.2).
library;

import 'kotlin_strings.dart';

/// Collapses `uname -s` output (or a Windows shell's error text) to one of the four families the
/// metrics parsers branch on.
///
/// An empty or unrecognised result deliberately maps to "Linux": it is the safest superset, and a
/// host that answers something unexpected is far more likely to be an unusual Unix than a Windows
/// box. Windows is detected from its *failure* text, since `uname` does not exist there.
String normaliseOs(String raw) {
  final s = raw.trim().lines.where((l) => !l.isBlankString).firstOrNull?.trim() ?? '';
  final lower = s.toLowerCase();
  if (lower.startsWith('linux')) return 'Linux';
  if (lower.startsWith('freebsd') ||
      lower.startsWith('openbsd') ||
      lower.startsWith('netbsd') ||
      lower.startsWith('dragonfly')) {
    return 'FreeBSD';
  }
  if (lower.startsWith('darwin')) return 'Darwin';
  if (lower.contains('windows') ||
      lower.contains('not recognized') ||
      lower.contains('commandnotfound')) {
    return 'Windows';
  }
  // Empty (missing @OS section) or unknown Unix-like → Linux, the safest superset.
  return 'Linux';
}

// ── shell safety ───────────────────────────────────────────────────────────────
//
// Requirement 12 (§17): the user chooses which hosts to talk to, but a *name* they typed — a unit,
// a path, a container — must never be able to become a command. Everything interpolated into a
// remote command string goes through [shellQuote].

/// Wraps [s] in single quotes for POSIX `sh`, escaping any embedded single quote.
///
/// Inside single quotes the shell expands nothing at all, so `$(…)`, backticks, `;`, `&&`, newlines
/// and globs are inert. The one character that can end the quoting is `'` itself, which is why it
/// becomes `'\''` — close, escaped literal quote, reopen.
String shellQuote(String s) => "'${s.replaceAll("'", r"'\''")}'";

// ── privilege elevation ────────────────────────────────────────────────────────
//
// The sudo password is NEVER interpolated into a command string. `sudo -S` reads it from the exec
// channel's stdin ([sudoStdin]), keeping it out of `ps`, auditd execve records and sshd debug logs
// on the remote — all places a command line is routinely visible to other users.

/// Elevates a single [cmd]. Pass the command *without* a leading `sudo`.
///
/// `-p ''` suppresses the prompt so it is never echoed back into the output the user sees.
String sudoWrap(String cmd, String sudoPassword) =>
    sudoPassword.trim().isNotEmpty ? "sudo -S -p '' $cmd 2>&1" : 'sudo -n $cmd 2>&1';

/// Elevates a whole [script].
///
/// [sudoWrap] only elevates the first command — in `sudo a && b`, `b` runs as the ordinary user.
/// This runs the lot under one `sh -c`, so chained operations are all privileged.
String sudoShWrap(String script, String sudoPassword) =>
    sudoPassword.trim().isNotEmpty
        ? "sudo -S -p '' sh -c ${shellQuote(script)} 2>&1"
        : 'sudo -n sh -c ${shellQuote(script)} 2>&1';

/// The stdin payload pairing with [sudoWrap]/[sudoShWrap]: the password and the newline `sudo -S`
/// waits for, or null on a NOPASSWD host. None of the wrapped scripts read stdin themselves, so the
/// line is consumed only by sudo.
String? sudoStdin(String sudoPassword) =>
    sudoPassword.trim().isNotEmpty ? '$sudoPassword\n' : null;

// ── processes ──────────────────────────────────────────────────────────────────

/// Linux: `pid,user,%cpu,%mem,vsz,etime,stat,comm`. The header line is dropped by the parser (its
/// pid is non-numeric). BusyBox `ps` has no `-eo`, hence the plain-output fallback, which the parser
/// also understands.
const processesLinux =
    'ps -eo pid,user,%cpu,%mem,vsz,etime,stat,comm 2>/dev/null | sort -k3 -rn | head -n 80'
    ' || ps w 2>/dev/null | head -n 80';

/// FreeBSD/macOS: the same eight columns via `-axo` (the keywords differ slightly).
const processesBsd =
    'ps -axo pid,user,pcpu,pmem,vsz,etime,state,comm 2>/dev/null | sort -k3 -rn | head -n 80';

/// Windows: emulates the same eight space-separated columns, sorted by CPU. `ProcessName` has no
/// spaces, so the parser's simple split holds.
const processesWindows =
    'powershell -NoProfile -Command "Get-CimInstance Win32_PerfFormattedData_PerfProc_Process | '
    'Where-Object { \$_.IDProcess -ne 0 } | Sort-Object PercentProcessorTime -Descending | '
    "Select-Object -First 80 | ForEach-Object { \$_.IDProcess.ToString() + ' NA ' + "
    "\$_.PercentProcessorTime + ' 0 ' + [int](\$_.WorkingSetPrivate/1024) + ' 00:00:00 R ' + \$_.Name }\"";

String processesFor(String os) => switch (normaliseOs(os)) {
      'Windows' => processesWindows,
      'FreeBSD' || 'Darwin' => processesBsd,
      _ => processesLinux,
    };

// ── services ───────────────────────────────────────────────────────────────────

/// Detects the init system rather than assuming systemd.
///
/// OpenRC hosts (Alpine, Gentoo) return `rc-status` output behind a marker so the parser switches
/// format; anything else returns a marker the UI turns into an explanation, instead of a silently
/// blank tab that looks like "this host runs nothing".
const servicesCommand =
    'if command -v systemctl >/dev/null 2>&1; then '
    '{ systemctl list-units --type=service --all --no-pager --no-legend --plain; '
    "echo '---ENABLED---'; systemctl list-unit-files --type=service --no-pager --no-legend --plain 2>/dev/null; }; "
    "elif command -v rc-status >/dev/null 2>&1; then echo '---OPENRC---'; rc-status -a 2>/dev/null; "
    "else echo '---NOSYSTEMD---'; fi";

/// start | stop | restart | status | enable | disable, against systemd or OpenRC.
///
/// [name] is shell-quoted: a unit name comes from remote output, and a host that returns a crafted
/// one must not be able to append a command.
String serviceAction(String name, String action, {String sudoPassword = ''}) {
  final quoted = shellQuote(name);
  final openRc = switch (action) {
    'enable' => 'rc-update add $quoted default',
    'disable' => 'rc-update delete $quoted -a',
    _ => 'rc-service $quoted $action',
  };
  final script = 'if command -v systemctl >/dev/null 2>&1; then systemctl $action $quoted; '
      'elif command -v rc-service >/dev/null 2>&1; then $openRc; '
      "else echo 'No supported service manager found' >&2; exit 1; fi";
  return sudoShWrap(script, sudoPassword);
}

// ── logs ───────────────────────────────────────────────────────────────────────

/// Host logs, falling through the sources a non-systemd host might have.
///
/// `journalctl` only exists on systemd, so Alpine/OpenWrt/BSD/macOS would otherwise return silently
/// empty output. The `---NOLOGS---` marker lets the UI say *why* the pane is empty.
String journalCommand({int lines = 300, String os = ''}) => switch (normaliseOs(os)) {
      'Windows' => _journalWindows(lines),
      'Darwin' => 'log show --last 1h --style syslog 2>/dev/null | tail -n $lines || '
          "echo '---NOLOGS---'",
      _ => 'if command -v journalctl >/dev/null 2>&1; then journalctl -n $lines --no-pager -o short-iso 2>/dev/null; '
          'elif command -v logread >/dev/null 2>&1; then logread 2>/dev/null | tail -n $lines; '
          'elif [ -r /var/log/messages ]; then tail -n $lines /var/log/messages 2>/dev/null; '
          'elif [ -r /var/log/syslog ]; then tail -n $lines /var/log/syslog 2>/dev/null; '
          "else echo '---NOLOGS---'; fi",
    };

String _journalWindows(int lines) =>
    'powershell -NoProfile -Command "Get-WinEvent -LogName System -MaxEvents $lines | '
    "ForEach-Object { \$_.TimeCreated.ToString('yyyy-MM-ddTHH:mm:ssK') + ' ' + "
    '\$_.ProviderName + \': \' + \$_.Message }"';

// ── host actions ───────────────────────────────────────────────────────────────

/// Reboots the host: sudo first, then a bare `reboot` for already-root or NOPASSWD wrappers.
String rebootCommand({String sudoPassword = ''}) =>
    '${sudoWrap('reboot', sudoPassword)} || reboot 2>&1';

/// Sends [signal] to [pid]. The pid is an int, so there is nothing here to quote.
String killProcessCommand(int pid, {int signal = 15}) => 'kill -$signal $pid 2>&1';

// ── host metrics ───────────────────────────────────────────────────────────────

/// Linux host metrics: one round trip, sections delimited by `@NAME` markers that
/// `parseMetrics` splits on. Every probe is `|| true` so a missing tool degrades one section rather
/// than failing the whole poll.
const metricsLinux =
    "echo '@OS'; uname -s 2>/dev/null || echo Linux; "
    // Distro pretty-name, so homelab OSes show by name instead of a bare "Linux".
    "echo '@DISTRO'; (. /etc/os-release 2>/dev/null && printf '%s\\n' \"\$PRETTY_NAME\") || true; "
    // Platform capabilities, so platform-specific quick scripts only appear on relevant hosts.
    "echo '@PLATFORM'; "
    'command -v pveversion >/dev/null 2>&1 && echo proxmox; '
    '{ [ -d /etc/casaos ] || command -v casaos >/dev/null 2>&1; } && echo casaos; '
    'command -v ha >/dev/null 2>&1 && echo homeassistant; '
    '{ command -v vcgencmd >/dev/null 2>&1 || grep -qi raspberry /proc/cpuinfo 2>/dev/null; } && echo raspberry; '
    'command -v docker >/dev/null 2>&1 && echo docker; '
    'true; '
    // Grabs the first line mentioning "cpu", catching GNU top ("%Cpu(s): … 95.6 id") and BusyBox
    // top ("CPU: … 98% idle") alike.
    "echo '@CPU'; LANG=C top -bn1 2>/dev/null | grep -i 'cpu' | head -1 || true; "
    "echo '@MEM'; LANG=C free -b 2>/dev/null | grep -i '^Mem' || true; "
    // /proc/meminfo fallback (kB) for BusyBox/Alpine, where `free -b` differs or is absent.
    "echo '@MEMINFO'; grep -iE '^(MemTotal|MemFree|MemAvailable):' /proc/meminfo 2>/dev/null || true; "
    // BusyBox df has no -B; the -Pk fallback is marked so the parser scales by 1024.
    "echo '@DISK'; df -PB1 / 2>/dev/null | tail -1 || df -Pk / 2>/dev/null | tail -1 | sed 's/^/KB1024 /' || true; "
    "echo '@DISKS'; df -PB1 2>/dev/null | tail -n +2 || df -Pk 2>/dev/null | tail -n +2 | sed 's/^/KB1024 /' || true; "
    "echo '@LOAD'; cat /proc/loadavg 2>/dev/null || true; "
    "echo '@UP'; cat /proc/uptime 2>/dev/null || true; "
    // Per-core CPU jiffies; rates come from the delta between polls.
    "echo '@STAT'; grep -E '^cpu[0-9]* ' /proc/stat 2>/dev/null || true; "
    // CPU temperature in millidegrees; the hottest thermal zone wins.
    "echo '@TEMP'; cat /sys/class/thermal/thermal_zone*/temp 2>/dev/null || true; "
    "echo '@NETDEV'; cat /proc/net/dev 2>/dev/null || true; "
    "echo '@DISKIO'; cat /proc/diskstats 2>/dev/null || true; "
    // Best-effort SMART health per whole disk; needs smartctl and root, silently empty otherwise.
    "echo '@SMART'; command -v smartctl >/dev/null 2>&1 && "
    'for d in /sys/block/sd? /sys/block/nvme?n? /sys/block/vd?; do '
    '[ -e "\$d" ] || continue; n=\$(basename "\$d"); '
    "h=\$(smartctl -H /dev/\$n 2>/dev/null | grep -iE 'overall-health|test result' | sed 's/.*: *//'); "
    '[ -n "\$h" ] && printf \'%s\\t%s\\n\' "\$n" "\$h"; done || true; '
    // Active TCP connections: ss preferred, /proc as the fallback.
    "echo '@TCP'; (ss -taH 2>/dev/null | wc -l) || (cat /proc/net/tcp /proc/net/tcp6 2>/dev/null | grep -c ':') || true; "
    "echo '@PROC'; ps -e --no-headers 2>/dev/null | wc -l || true";

/// FreeBSD/OpenBSD metrics via sysctl/df/netstat — there is no /proc, so per-core CPU, disk I/O and
/// SMART are skipped rather than faked.
const metricsBsd =
    "echo '@OS'; uname -s; "
    "echo '@CPU'; top -b -d1 2>/dev/null | grep -i 'CPU:' | head -1 || true; "
    "echo '@SYSMEM'; echo phys \$(sysctl -n hw.physmem 2>/dev/null); "
    'echo pagesize \$(sysctl -n hw.pagesize 2>/dev/null); '
    'echo free \$(sysctl -n vm.stats.vm.v_free_count 2>/dev/null); '
    'echo inactive \$(sysctl -n vm.stats.vm.v_inactive_count 2>/dev/null); '
    'echo cache \$(sysctl -n vm.stats.vm.v_cache_count 2>/dev/null); '
    "echo '@DISK'; df -k / 2>/dev/null | tail -1 || true; "
    "echo '@DISKS'; df -k 2>/dev/null | tail -n +2 || true; "
    "echo '@LOADAVG'; sysctl -n vm.loadavg 2>/dev/null || true; "
    "echo '@BOOT'; sysctl -n kern.boottime 2>/dev/null || true; "
    "echo '@NOW'; date +%s 2>/dev/null || true; "
    "echo '@NETSTAT'; netstat -ibn 2>/dev/null || true; "
    "echo '@TCP'; netstat -an 2>/dev/null | grep -c ESTABLISHED || true; "
    "echo '@PROC'; ps -ax 2>/dev/null | wc -l || true";

/// macOS: like [metricsBsd], but memory comes from `vm_stat` plus `hw.memsize`.
const metricsDarwin =
    "echo '@OS'; uname -s; "
    "echo '@CPU'; top -l1 -n0 2>/dev/null | grep -i 'CPU usage' | head -1 || true; "
    "echo '@MEMSIZE'; sysctl -n hw.memsize 2>/dev/null || true; "
    "echo '@VMSTAT'; vm_stat 2>/dev/null || true; "
    "echo '@DISK'; df -k / 2>/dev/null | tail -1 || true; "
    "echo '@DISKS'; df -k 2>/dev/null | tail -n +2 || true; "
    "echo '@LOADAVG'; sysctl -n vm.loadavg 2>/dev/null || true; "
    "echo '@BOOT'; sysctl -n kern.boottime 2>/dev/null || true; "
    "echo '@NOW'; date +%s 2>/dev/null || true; "
    "echo '@NETSTAT'; netstat -ibn 2>/dev/null || true; "
    "echo '@TCP'; netstat -an 2>/dev/null | grep -c ESTABLISHED || true; "
    "echo '@PROC'; ps -ax 2>/dev/null | wc -l || true";

/// Windows (PowerShell), best effort: CPU load %, memory, logical disks, uptime, process count.
const metricsWindows =
    'powershell -NoProfile -Command "'
    "Write-Output '@OS'; Write-Output 'Windows'; "
    "Write-Output '@WINCPU'; (Get-CimInstance Win32_Processor | Measure-Object -Property LoadPercentage -Average).Average; "
    "Write-Output '@WINMEM'; \$o=Get-CimInstance Win32_OperatingSystem; "
    "Write-Output (([int64]\$o.TotalVisibleMemorySize*1024).ToString()+' '+([int64]\$o.FreePhysicalMemory*1024).ToString()); "
    "Write-Output '@WINDISK'; Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' | ForEach-Object { "
    "\$_.DeviceID+' '+\$_.Size+' '+\$_.FreeSpace }; "
    "Write-Output '@WINUP'; [int64]((Get-Date)-(Get-CimInstance Win32_OperatingSystem).LastBootUpTime).TotalSeconds; "
    "Write-Output '@WINPROC'; (Get-Process).Count"
    '"';

/// Per-OS host-metrics probe.
String metricsFor(String os) => switch (normaliseOs(os)) {
      'FreeBSD' => metricsBsd,
      'Darwin' => metricsDarwin,
      'Windows' => metricsWindows,
      _ => metricsLinux,
    };

// ── container runtimes (Docker / Podman) ───────────────────────────────────────
//
// A host can run both. Every probe below therefore queries each runtime that answers and prefixes
// its rows with the runtime name, because nothing else on a row says which engine owns it — the same
// `repo:tag` can be pulled into each, and each has its own `bridge` network.

/// Resolves the container binary at run time: whichever of docker/podman actually answers `ps`.
///
/// A binary whose daemon or socket the user cannot reach does not count — it would otherwise be
/// selected and then fail on every call.
const _cr = r'"$(if command -v docker >/dev/null 2>&1 && docker ps >/dev/null 2>&1; then command -v docker; '
    r'elif command -v podman >/dev/null 2>&1 && podman ps >/dev/null 2>&1; then command -v podman; '
    r'elif command -v docker >/dev/null 2>&1; then command -v docker; else command -v podman; fi)"';

/// The container binary for an explicit [runtime], falling back to the run-time probe.
String _runtimeCommand(String runtime) => switch (runtime.toLowerCase()) {
      'docker' => 'docker',
      'podman' => 'podman',
      _ => _cr,
    };

// Docker and Podman expose compose labels through *incompatible* template syntaxes, so the ps
// format branches on the runtime:
//   • Docker's psReporter has a `.Label "key"` method; its `.Labels` is a comma-joined string, so
//     `index .Labels "key"` errors there ("cannot index slice/array with type string").
//   • Podman's psReporter has no `.Label` method at all; its `.Labels` IS a map, reachable via
//     `index .Labels "key"`.
const _psFieldsDocker =
    r'{{.ID}}\t{{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}\t{{.Label "com.docker.compose.project"}}\t{{.Label "com.docker.compose.service"}}\t{{.Label "com.docker.compose.project.working_dir"}}\t{{.Label "com.docker.compose.project.config_files"}}\t{{.CreatedAt}}';
const _psFieldsPodman =
    r'{{.ID}}\t{{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}\t{{index .Labels "com.docker.compose.project"}}\t{{index .Labels "com.docker.compose.service"}}\t{{index .Labels "com.docker.compose.project.working_dir"}}\t{{index .Labels "com.docker.compose.project.config_files"}}\t{{.CreatedAt}}';

/// All containers including stopped ones, tab-separated and `--no-trunc` so parsing is unambiguous.
const dockerPsCommand = 'found=0; '
    "if command -v docker >/dev/null 2>&1 && docker ps >/dev/null 2>&1; then found=1; docker ps -a --no-trunc --format 'docker\\t$_psFieldsDocker'; fi; "
    "if command -v podman >/dev/null 2>&1 && podman ps >/dev/null 2>&1; then found=1; podman ps -a --no-trunc --format 'podman\\t$_psFieldsPodman'; fi; "
    'if [ "\$found" = 0 ]; then if $_cr --version | grep -qi podman; then '
    "$_cr ps -a --no-trunc --format 'podman\\t$_psFieldsPodman'; else "
    "$_cr ps -a --no-trunc --format 'docker\\t$_psFieldsDocker'; fi; fi";

/// One line per usable runtime on the host, gated on `ps` actually answering.
const dockerRuntimesCommand =
    'if command -v docker >/dev/null 2>&1 && docker ps >/dev/null 2>&1; then echo docker; fi; '
    'if command -v podman >/dev/null 2>&1 && podman ps >/dev/null 2>&1; then echo podman; fi';

/// Per-container restart counts.
///
/// Docker's inspect template field is `.Id`; Podman's is `.ID` (its JSON prints "Id" but the Go
/// struct field is `ID`, so `.Id` errors). `.RestartCount` is identical on both.
const dockerRestartsCommand =
    'if command -v docker >/dev/null 2>&1 && docker ps >/dev/null 2>&1; then ids=\$(docker ps -aq); '
    "[ -n \"\$ids\" ] && docker inspect --format 'docker\\t{{.Id}}\\t{{.RestartCount}}' \$ids 2>/dev/null || true; fi; "
    'if command -v podman >/dev/null 2>&1 && podman ps >/dev/null 2>&1; then ids=\$(podman ps -aq); '
    "[ -n \"\$ids\" ] && podman inspect --format 'podman\\t{{.ID}}\\t{{.RestartCount}}' \$ids 2>/dev/null || true; fi";

const _imageFields = r'{{.ID}}\t{{.Repository}}\t{{.Tag}}\t{{.Size}}\t{{.CreatedSince}}';

const dockerImagesCommand = 'found=0; '
    "if command -v docker >/dev/null 2>&1 && docker ps >/dev/null 2>&1; then found=1; docker images --no-trunc --format 'docker\\t$_imageFields'; fi; "
    "if command -v podman >/dev/null 2>&1 && podman ps >/dev/null 2>&1; then found=1; podman images --no-trunc --format 'podman\\t$_imageFields'; fi; "
    'if [ "\$found" = 0 ]; then if $_cr --version | grep -qi podman; then '
    "$_cr images --no-trunc --format 'podman\\t$_imageFields'; else "
    "$_cr images --no-trunc --format 'docker\\t$_imageFields'; fi; fi";

/// Volumes, with sizes where the runtime can report them.
///
/// Three layered fallbacks, because the same information is exposed three different ways:
///   1. `system df -v --format` — works on Docker and recent Podman; gives size and link count.
///   2. Podman's *text* `system df -v` — column-parses the "Local Volumes" section. The awk state
///      machine enters on the section heading, **arms on the column header**, then reads rows until
///      a blank line or the next `Header:` line. Arming on the column header is what stops the blank
///      line sitting between the heading and the header from ending the section immediately.
///   3. `volume ls` — always available; no size or links, but the list is still correct.
///
/// Volume names containing spaces are out of scope for the text fallback.
const dockerVolumesCommand =
    r"""ot_vols() { rt="$1"; "$rt" system df -v --format '{{range .Volumes}}{{.Name}}\t{{.Driver}}\t{{.Mountpoint}}\t{{.Size}}\t{{.Links}}\n{{end}}' 2>/dev/null || "$rt" system df -v 2>/dev/null | awk '/^Local Volumes/ { f=1; seen=0; next } f && $1=="VOLUME" && $2=="NAME" { seen=1; next } f && seen && /^[[:space:]]*$/ { f=0; next } f && seen && /^[A-Za-z].*:/ { f=0 } f && seen && NF>=3 { print $1 "\tlocal\t\t" $3 "\t" $2 }' || "$rt" volume ls --format '{{.Name}}\t{{.Driver}}\t{{.Mountpoint}}\t\t'; }; found=0; if command -v docker >/dev/null 2>&1 && docker ps >/dev/null 2>&1; then found=1; ot_vols docker | sed 's/^/docker\t/'; fi; if command -v podman >/dev/null 2>&1 && podman ps >/dev/null 2>&1; then found=1; ot_vols podman | sed 's/^/podman\t/'; fi; if [ "$found" = 0 ]; then if """
    '$_cr'
    r""" --version | grep -qi podman; then ot_vols """
    '$_cr'
    r""" | sed 's/^/podman\t/'; else ot_vols """
    '$_cr'
    r""" | sed 's/^/docker\t/'; fi; fi""";

const _networkFields = r'{{.ID}}\t{{.Name}}\t{{.Driver}}';

const dockerNetworksCommand = 'found=0; '
    "if command -v docker >/dev/null 2>&1 && docker ps >/dev/null 2>&1; then found=1; docker network ls --format 'docker\\t$_networkFields' 2>/dev/null; fi; "
    "if command -v podman >/dev/null 2>&1 && podman ps >/dev/null 2>&1; then found=1; podman network ls --format 'podman\\t$_networkFields' 2>/dev/null; fi; "
    'if [ "\$found" = 0 ]; then if $_cr --version | grep -qi podman; then '
    "$_cr network ls --format 'podman\\t$_networkFields'; else "
    "$_cr network ls --format 'docker\\t$_networkFields'; fi; fi";

// ── container actions ──────────────────────────────────────────────────────────
//
// Every identifier is shell-quoted. Container and volume names come from remote output, and a host
// that returns a crafted one must not be able to append a command (§17).

/// start | stop | restart | pause | unpause | remove, against one container.
String dockerAction(String id, String action, {String runtime = ''}) {
  final verb = action == 'remove' ? 'rm -f' : action;
  return '${_runtimeCommand(runtime)} $verb ${shellQuote(id)} 2>&1';
}

String dockerImageAction(String id, String action, {String runtime = ''}) {
  final verb = action == 'remove' ? 'rmi -f' : action;
  return '${_runtimeCommand(runtime)} $verb ${shellQuote(id)} 2>&1';
}

String dockerVolumeAction(String name, String action, {String runtime = ''}) {
  final verb = action == 'remove' ? 'volume rm -f' : action;
  return '${_runtimeCommand(runtime)} $verb ${shellQuote(name)} 2>&1';
}

String dockerNetworkAction(String id, String action, {String runtime = ''}) {
  final verb = action == 'remove' ? 'network rm' : action;
  return '${_runtimeCommand(runtime)} $verb ${shellQuote(id)} 2>&1';
}

/// Removes every unused image, on each runtime the host actually has.
String dockerPruneImages() =>
    '{ command -v docker >/dev/null 2>&1 && docker ps >/dev/null 2>&1 && docker image prune -a -f; true; } 2>&1; '
    '{ command -v podman >/dev/null 2>&1 && podman ps >/dev/null 2>&1 && podman image prune -a -f; true; } 2>&1';

/// Removes every unused volume.
///
/// `-a` is deliberate: plain `volume prune -f` removes only *anonymous* unused volumes on current
/// Docker and Podman, which would not match the UI's "unused volumes" wording.
String dockerPruneVolumes() =>
    '{ command -v docker >/dev/null 2>&1 && docker ps >/dev/null 2>&1 && docker volume prune -a -f; true; } 2>&1; '
    '{ command -v podman >/dev/null 2>&1 && podman ps >/dev/null 2>&1 && podman volume prune -a -f; true; } 2>&1';
