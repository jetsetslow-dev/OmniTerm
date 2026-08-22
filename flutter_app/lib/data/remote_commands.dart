/// Ported from `data/RemoteParsers.kt`'s `RemoteCommands` object.
///
/// **Partial port.** Only [normaliseOs] is here so far, because `remote_parsers.dart` dispatches on
/// it. The ~940 lines of shell command strings land with the screens that issue them
/// so parsing and remote behaviour stay independently testable.
library;

import 'dart:convert';
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
String sudoShWrap(String script, String sudoPassword) => sudoPassword.trim().isNotEmpty
    ? "sudo -S -p '' sh -c ${shellQuote(script)} 2>&1"
    : 'sudo -n sh -c ${shellQuote(script)} 2>&1';

/// The stdin payload pairing with [sudoWrap]/[sudoShWrap]: the password and the newline `sudo -S`
/// waits for, or null on a NOPASSWD host. None of the wrapped scripts read stdin themselves, so the
/// line is consumed only by sudo.
String? sudoStdin(String sudoPassword) => sudoPassword.trim().isNotEmpty ? '$sudoPassword\n' : null;

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
  final script =
      'if command -v systemctl >/dev/null 2>&1; then systemctl $action $quoted; '
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
  'Darwin' =>
    'log show --last 1h --style syslog 2>/dev/null | tail -n $lines || '
        "echo '---NOLOGS---'",
  // Each source is tried until one actually *produces* something, rather than stopping at the
  // first one that merely exists. A BusyBox host ships `logread` whether or not syslogd is
  // running, and when it is not, `logread` fails to stderr and exits — so an `elif` chain
  // stopped there, printed nothing, never emitted the marker, and left the pane silently blank
  // on most containers (§15.10).
  _ =>
    r'L=""; '
        'if command -v journalctl >/dev/null 2>&1; then '
        r'L=$(journalctl -n '
        '$lines'
        r' --no-pager -o short-iso 2>/dev/null); fi; '
        r'if [ -z "$L" ] && command -v logread >/dev/null 2>&1; then '
        r'L=$(logread 2>/dev/null | tail -n '
        '$lines'
        r'); fi; '
        r'if [ -z "$L" ] && [ -r /var/log/messages ]; then '
        r'L=$(tail -n '
        '$lines'
        r' /var/log/messages 2>/dev/null); fi; '
        r'if [ -z "$L" ] && [ -r /var/log/syslog ]; then '
        r'L=$(tail -n '
        '$lines'
        r' /var/log/syslog 2>/dev/null); fi; '
        r'''if [ -z "$L" ]; then echo '---NOLOGS---'; else printf '%s
' "$L"; fi''',
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

/// Asks the host what it is, once, before any command that has per-OS variants.
///
/// Windows has no `uname`, so it is identified by the *failure*: whatever its shell says when the
/// command is not found, `normaliseOs` recognises. The fallback echo means the reply is never empty,
/// which would otherwise be indistinguishable from an unreachable host.
const osProbeCommand = 'uname -s 2>/dev/null || echo Windows';

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
const _cr =
    r'"$(if command -v docker >/dev/null 2>&1 && docker ps >/dev/null 2>&1; then command -v docker; '
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
const dockerPsCommand =
    'found=0; '
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

const dockerImagesCommand =
    'found=0; '
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

const dockerNetworksCommand =
    'found=0; '
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

/// Interactive shell inside a container, preferring bash and falling back to POSIX sh.
String dockerExecShell(String id, {String runtime = ''}) =>
    '${_runtimeCommand(runtime)} exec -it ${shellQuote(id)} '
    "sh -c 'exec bash 2>/dev/null || exec sh'";

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

/// Removes every network that no container uses, on each available runtime.
String dockerPruneNetworks() =>
    '{ command -v docker >/dev/null 2>&1 && docker ps >/dev/null 2>&1 && docker network prune -f; true; } 2>&1; '
    '{ command -v podman >/dev/null 2>&1 && podman ps >/dev/null 2>&1 && podman network prune -f; true; } 2>&1';

// ── docker compose ─────────────────────────────────────────────────────────────

/// Resolves the compose entrypoint at run time into `$OT_COMPOSE`.
///
/// There are four in the wild — `docker compose`, `docker-compose`, `podman compose`,
/// `podman-compose` — and which one a host has is not predictable from which engine it runs.
///
/// Podman's `compose` subcommand is only a dispatcher to an external provider and may select Docker
/// Compose even when native `podman-compose` is installed, so the explicit provider is preferred.
/// A host with none exits non-zero with a message rather than running a half-formed command.
String _composeResolve(String runtime) => switch (runtime.toLowerCase()) {
  'docker' =>
    'OT_CR=docker; '
        'if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then OT_COMPOSE="docker compose"; '
        'elif command -v docker-compose >/dev/null 2>&1; then OT_COMPOSE="docker-compose"; '
        "else echo 'No Docker Compose found on host' >&2; exit 1; fi",
  'podman' =>
    'OT_CR=podman; '
        'if command -v podman-compose >/dev/null 2>&1; then OT_COMPOSE="podman-compose"; '
        'elif command -v podman >/dev/null 2>&1 && podman compose version >/dev/null 2>&1; then OT_COMPOSE="podman compose"; '
        "else echo 'No Podman Compose provider found on host' >&2; exit 1; fi",
  _ =>
    'OT_CR=$_cr; '
        'if [ -n "\$OT_CR" ] && "\$OT_CR" --version 2>/dev/null | grep -qi podman; then '
        'if command -v podman-compose >/dev/null 2>&1; then OT_COMPOSE="podman-compose"; '
        'elif "\$OT_CR" compose version >/dev/null 2>&1; then OT_COMPOSE="\$OT_CR compose"; '
        "else echo 'No Podman Compose provider found on host' >&2; exit 1; fi; "
        'elif [ -n "\$OT_CR" ]; then '
        'if "\$OT_CR" compose version >/dev/null 2>&1; then OT_COMPOSE="\$OT_CR compose"; '
        'elif command -v docker-compose >/dev/null 2>&1; then OT_COMPOSE="docker-compose"; '
        "else echo 'No Docker Compose found on host' >&2; exit 1; fi; "
        'elif command -v docker-compose >/dev/null 2>&1; then OT_COMPOSE="docker-compose"; '
        'elif command -v podman-compose >/dev/null 2>&1; then OT_COMPOSE="podman-compose"; '
        "else echo 'No docker/podman compose found on host' >&2; exit 1; fi",
};

/// `-f <file>… -p <project>`, every value shell-quoted.
String _composeFlags(String project, String configFiles) {
  final configFlags = configFiles
      .split(',')
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty)
      .map((s) => '-f ${shellQuote(s)}')
      .join(' ');
  return [configFlags, '-p ${shellQuote(project)}'].where((s) => s.isNotEmpty).join(' ');
}

/// Runs a compose action against a stack.
///
/// Always `cd`s into the stack's working directory first: compose resolves relative bind-mount
/// paths and `.env` against the working directory, so running from elsewhere can silently produce a
/// *different* stack from the same file.
String dockerComposeAction(
  String project,
  String workingDir,
  String configFiles,
  String action, {
  String? service,
  int? replicas,
  bool removeOrphans = false,
  String runtime = '',
}) {
  final flags = _composeFlags(project, configFiles);
  final orphans = removeOrphans ? ' --remove-orphans' : '';
  final resolver = _composeResolve(runtime);

  // "update" is multi-step and stays guarded by the cd, so it builds its own tail rather than
  // plugging one verb into the shared template. Pull registry images (non-fatal, so a registry
  // login hiccup cannot block a build), then build --pull to refresh base images, then recreate.
  if (action == 'update') {
    const c = r'$OT_COMPOSE';
    final tail =
        '{ $c $flags pull --ignore-buildable 2>/dev/null || $c $flags pull 2>/dev/null || true; } && '
        '$c $flags build --pull && $c $flags up -d$orphans && $c $flags ps';
    return '$resolver && cd ${shellQuote(workingDir)} && $tail 2>&1';
  }

  final quotedService = shellQuote(service ?? '');
  final verb = switch (action) {
    'build' => 'build --pull',
    'pull' => 'pull',
    'down' => 'down$orphans',
    'up' => 'up -d$orphans',
    'forceRecreate' => 'up -d --force-recreate$orphans',
    'restart' => 'restart',
    'logs' => 'logs --tail 200',
    'followLogs' => service == null ? 'logs -f --tail 100' : 'logs -f --tail 100 $quotedService',
    'config' => 'config',
    'ps' => 'ps',
    'serviceLogs' => 'logs --tail 200 $quotedService',
    'serviceRestart' => 'restart $quotedService',
    'serviceStop' => 'stop $quotedService',
    'serviceRemove' => 'rm -sf $quotedService',
    // A negative replica count is not a scale-down, it is a malformed command; clamp at zero.
    'scale' => 'up -d --scale $quotedService=${(replicas ?? 1) < 0 ? 0 : (replicas ?? 1)}',
    'removeOrphans' => 'up -d --remove-orphans',
    _ => 'ps',
  };
  return '$resolver && cd ${shellQuote(workingDir)} && \$OT_COMPOSE $flags $verb 2>&1';
}

/// Checks that a remembered stack's compose file still exists before acting on it.
///
/// A file can be moved or deleted behind the app's back, and compose's own missing-file error is
/// confusing; this lets the UI say plainly that the file is gone and offer to forget the stack.
String composeConfigPresent(String workingDir, String configFiles) {
  // `~` is the shell's, not a path component, so it must expand rather than be quoted away.
  String expand(String p) =>
      p.startsWith('~/') ? '"\$HOME"/${shellQuote(p.substring(2))}' : shellQuote(p);

  final dir = workingDir.endsWith('/')
      ? workingDir.substring(0, workingDir.length - 1)
      : workingDir;
  final recorded = configFiles
      .split(',')
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty)
      .map((s) => (s.startsWith('/') || s.startsWith('~/')) ? s : '$dir/$s')
      .toList();

  final test = recorded.isNotEmpty
      // Every recorded file must be present: compose merges them, and a missing overlay changes
      // what comes up rather than failing outright.
      ? recorded.map((p) => '[ -f ${expand(p)} ]').join(' && ')
      : [
          'compose.yaml',
          'compose.yml',
          'docker-compose.yml',
          'docker-compose.yaml',
        ].map((n) => '[ -f ${expand('$dir/$n')} ]').join(' || ');

  return 'if { $test; } 2>/dev/null; then echo OMNITERM_COMPOSE_OK; else echo OMNITERM_COMPOSE_MISSING; fi';
}

/// Reads the exact compose file reported by the runtime; absence is distinct from an empty file.
String composeRead(String composeFilePath) {
  final path = composeFilePath.startsWith('~/')
      ? '\$HOME/${shellQuote(composeFilePath.substring(2))}'
      : shellQuote(composeFilePath);
  return 'cat $path 2>/dev/null || echo OMNITERM_NO_FILE';
}

/// Atomically validates, swaps and starts a Compose file, restoring its backup on failure.
String composeDeploy(
  String composeFilePath,
  String project,
  String yaml, {
  String workingDir = '',
  String configFiles = '',
  String runtime = '',
}) {
  String expand(String path) =>
      path.startsWith('~/') ? '\$HOME/${shellQuote(path.substring(2))}' : shellQuote(path);
  String resolve(String path) => path.startsWith('/') || path.startsWith('~/') || workingDir.isEmpty
      ? path
      : '${workingDir.replaceFirst(RegExp(r'/+$'), '')}/$path';
  String flags(String replacement) {
    final files = configFiles
        .split(',')
        .map((file) => file.trim())
        .where((file) => file.isNotEmpty);
    var matched = false;
    final rendered = <String>[];
    for (final raw in files) {
      final resolved = resolve(raw);
      if (resolved == composeFilePath) {
        rendered.add('-f $replacement');
        matched = true;
      } else {
        rendered.add('-f ${expand(resolved)}');
      }
    }
    if (!matched) rendered.insert(0, '-f $replacement');
    rendered.add('-p ${shellQuote(project)}');
    return rendered.join(' ');
  }

  final encoded = base64Encode(utf8.encode(yaml));
  final file = expand(composeFilePath);
  final backup = expand('$composeFilePath.omniterm.bak');
  final rawDirectory = composeFilePath.contains('/')
      ? composeFilePath.substring(0, composeFilePath.lastIndexOf('/'))
      : '.';
  final directory = expand(rawDirectory.isEmpty ? '/' : rawDirectory);
  final stagedFlags = flags('"\$tmp"');
  final liveFlags = flags(file);
  final resolver = _composeResolve(runtime);
  return '$resolver && umask 077 && mkdir -p $directory '
      '&& tmp=\$(mktemp $directory/.omniterm-compose.XXXXXX) '
      '&& err=\$(mktemp $directory/.omniterm-compose-err.XXXXXX) '
      "&& trap 'rm -f \"\$tmp\" \"\$err\"' EXIT "
      '&& { existed=0; [ -f $file ] && existed=1; true; } '
      "&& { printf '%s' ${shellQuote(encoded)} | base64 -d > \"\$tmp\" 2>/dev/null "
      "|| printf '%s' ${shellQuote(encoded)} | base64 --decode > \"\$tmp\" 2>/dev/null "
      "|| printf '%s' ${shellQuote(encoded)} | base64 -D > \"\$tmp\"; } "
      '&& { if ! \$OT_COMPOSE $stagedFlags config >/dev/null 2>"\$err"; then '
      "echo 'VALIDATION FAILED — stack unchanged:' >&2; cat \"\$err\" >&2; exit 1; fi; } "
      '&& { cat "\$err" 2>/dev/null || true; } '
      '&& { if [ -f $file ]; then cp $file $backup; fi; } '
      '&& mv "\$tmp" $file '
      '&& { if ! \$OT_COMPOSE $liveFlags up -d 2>&1; then '
      "if [ \"\$existed\" = 1 ] && [ -f $backup ]; then echo 'DEPLOY FAILED — restoring previous compose file' >&2; mv $backup $file; "
      "else echo 'DEPLOY FAILED — removing new compose file' >&2; rm -f $file; fi; exit 1; fi; } "
      "&& echo 'OMNITERM_DEPLOY_OK'";
}

/// Measures how much disk a directory actually uses.
///
/// `du -sh` rather than summing the listing: a directory's own size in a file listing is the size of
/// its *index*, not its contents, so a browser that shows "4.0 KB" for a folder holding 80 GB is
/// technically right and useless. This is the answer to the question people actually open a file
/// browser to ask.
///
/// `-x` stays on one filesystem, so measuring `/` on a host with network mounts does not wander off
/// into them and hang. Errors are folded into the output rather than discarded, because `du` reports
/// a *partial* total when it cannot read part of the tree — and a partial total presented as a
/// final one is worse than either the number or the warning alone.
String folderSizeCommand(String path) => 'du -shx -- ${shellQuote(path)} 2>&1';

String archiveCreateCommand(
  String directory,
  String archiveName,
  List<String> names,
  String format,
) {
  final args = names.map(shellQuote).join(' ');
  final target = shellQuote(archiveName);
  final create = switch (format) {
    'zip' => 'zip -r -- $target $args',
    'tar' => 'tar -cf $target -- $args',
    '7z' => '7z a -y -- $target $args',
    _ => 'tar -czf $target -- $args',
  };
  return 'cd -- ${shellQuote(directory.isEmpty ? '.' : directory)} && '
      'rm -f -- $target && $create && printf \'\\nOMNITERM_ARCHIVE_OK\\n\'';
}

String archiveExtractCommand(String directory, String archiveName) {
  final dir = shellQuote(directory.isEmpty ? '.' : directory);
  final file = shellQuote(archiveName);
  final lower = archiveName.toLowerCase();
  final extract = switch (lower) {
    _ when lower.endsWith('.zip') => 'unzip -o -- $file',
    _ when lower.endsWith('.tar.gz') || lower.endsWith('.tgz') => 'tar -xzf $file',
    _ when lower.endsWith('.tar.bz2') || lower.endsWith('.tbz2') => 'tar -xjf $file',
    _ when lower.endsWith('.tar.xz') || lower.endsWith('.txz') => 'tar -xJf $file',
    _ when lower.endsWith('.tar') => 'tar -xf $file',
    _ when lower.endsWith('.7z') => '7z x -y -- $file',
    _ when lower.endsWith('.rar') => 'unrar x -o+ -- $file',
    _ => 'false',
  };
  return 'cd -- $dir && $extract && printf \'\\nOMNITERM_EXTRACT_OK\\n\'';
}

/// What `du` managed to measure.
class FolderSize {
  const FolderSize(this.size, {required this.complete});

  /// The human-readable total, e.g. `1.2G`.
  final String size;

  /// False when `du` could not read part of the tree, so [size] is a floor rather than the answer.
  ///
  /// Kept separate rather than folded into the string because the caller has to *say* it: observed
  /// against a real host, `du -shx /root` as an unprivileged user prints a warning, prints `4.0K`,
  /// and exits non-zero. Reporting `4.0K` alone would be a confident wrong answer about a directory
  /// that is far larger; reporting nothing would throw away a real lower bound.
  final bool complete;
}

/// The size `du` reported, or null when the output carries none.
///
/// `du` prints `SIZE\tPATH`, and on a permission error prints warning lines *as well*, so the size
/// is taken from the last line that starts with one rather than from the first line of output.
FolderSize? parseFolderSize(String output) {
  String? size;
  var complete = true;
  for (final line in const LineSplitter().convert(output)) {
    final match = RegExp(r'^\s*([0-9][0-9.,]*[KMGTPE]?)\s+\S').firstMatch(line);
    if (match != null) {
      size = match.group(1);
      continue;
    }
    // Anything else on stderr means part of the tree was not counted.
    if (line.trim().isNotEmpty) complete = false;
  }
  return size == null ? null : FolderSize(size, complete: complete);
}

/// How many search hits are fetched before the rest are declared "more".
const remoteSearchMaxHits = 200;

/// One result from a host-wide search.
class RemoteSearchHit {
  const RemoteSearchHit(this.path, {required this.isDirectory});

  final String path;
  final bool isDirectory;
}

/// How many hits a share walk collects before declaring the rest "more".
const shareSearchMaxHits = 500;

/// How many directories a share walk visits before giving up.
///
/// A share is walked one `list` round trip at a time, so an unbounded walk of a deep tree on a slow
/// link runs until the user gives up. Compose uses the same two numbers (`ui/AppViewModel.kt:8021`).
const shareSearchDirBudget = 4000;

/// Builds the name matcher for a share walk.
///
/// Follows the same rule as [remoteSearchCommand] rather than Compose's separate Wildcards toggle:
/// a query already carrying `*` or `?` is taken as a pattern, anything else is matched anywhere in
/// the name. Compose asks the user to declare which they meant; inferring it means one less control
/// and the same answer for every query that is not literally searching for an asterisk.
bool Function(String name) shareSearchMatcher(String query) {
  final term = query.trim();
  if (!term.contains('*') && !term.contains('?')) {
    final needle = term.toLowerCase();
    return (name) => name.toLowerCase().contains(needle);
  }
  final pattern = StringBuffer('^');
  for (final ch in term.split('')) {
    if (ch == '*') {
      pattern.write('.*');
    } else if (ch == '?') {
      pattern.write('.');
    } else {
      pattern.write(RegExp.escape(ch));
    }
  }
  pattern.write(r'$');
  final regex = RegExp(pattern.toString(), caseSensitive: false);
  return regex.hasMatch;
}

/// Searches a host for names matching [query], starting at [base].
///
/// A plain `find` prints paths and nothing else, so the type of each hit — file or directory —
/// would be unknown and every result would have to be probed separately. The `while read` loop
/// tags each line instead. It is deliberately POSIX `sh`: GNU `find -printf` does not exist on
/// BSD, macOS or busybox, which between them cover a large part of what people run at home.
///
/// One more hit than the caller wants is fetched, which is how truncation is *known* rather than
/// guessed at — see [parseRemoteSearch].
///
/// `2>/dev/null` because a walk of a large tree as an unprivileged user produces pages of
/// permission noise that would swamp the results. The screen says plainly that a search covers what
/// the login can read, which is a statement that is always true rather than a per-run claim.
String remoteSearchCommand(String base, String query, {int maxHits = remoteSearchMaxHits}) {
  final root = base.trim().isEmpty ? '/' : base;
  final term = query.trim();
  // A query already carrying a wildcard is taken at its word; anything else is matched anywhere in
  // the name, because that is what a person typing three letters into a search box means.
  final pattern = term.contains('*') || term.contains('?') ? term : '*$term*';
  return 'find ${shellQuote(root)} -iname ${shellQuote(pattern)} 2>/dev/null | '
      'head -n ${maxHits + 1} | '
      'while IFS= read -r p; do '
      'if [ -d "\$p" ]; then printf "d\\t%s\\n" "\$p"; else printf "f\\t%s\\n" "\$p"; fi; '
      'done';
}

/// The hits [remoteSearchCommand] produced, and whether there were more.
///
/// [base] is dropped from the results: `find` emits the directory it was pointed at whenever that
/// directory's own name matches, and offering the folder you are already in as a search result is
/// noise.
({List<RemoteSearchHit> hits, bool truncated}) parseRemoteSearch(
  String output, {
  required String base,
  int maxHits = remoteSearchMaxHits,
}) {
  final hits = <RemoteSearchHit>[];
  for (final line in const LineSplitter().convert(output)) {
    final tab = line.indexOf('\t');
    if (tab <= 0) continue;
    final path = line.substring(tab + 1).trim();
    if (path.isEmpty || path == base) continue;
    hits.add(RemoteSearchHit(path, isDirectory: line.startsWith('d')));
  }
  // The extra hit is the evidence. Counting a full page as "probably more" would cry wolf on a
  // search that happened to return exactly the limit.
  final truncated = hits.length > maxHits;
  return (hits: truncated ? hits.take(maxHits).toList() : hits, truncated: truncated);
}

// ── sudo file access ───────────────────────────────────────────────────────────

/// Marks where a privileged command's real output begins.
///
/// **This exists because `sudo` talks.** On first use in a session it prints its lecture — "We trust
/// you have received the usual lecture…" — to stderr, and every sudo wrapper here folds stderr into
/// the output so failures are visible. Without a marker that lecture would be prepended *to the
/// file being read*, land in the editor, and be written back on save. Verified against a real host:
/// the lecture appears before the command runs, so anything after the marker is the command's own
/// output and nothing else.
const sudoOutputMarker = '---OMNITERM-BEGIN---';

/// Reads a file the ordinary login cannot, with `sudo cat`.
///
/// SFTP has no way to elevate — the protocol has no concept of it — so a protected file has to come
/// back over an exec channel instead.
String sudoReadCommand(String path, String sudoPassword) => sudoShWrap(
  "printf '%s\n' ${shellQuote(sudoOutputMarker)}; cat -- ${shellQuote(path)}",
  sudoPassword,
);

/// The file contents from [sudoReadCommand], or null when the command never ran.
///
/// Null means sudo refused — a wrong password, no sudo rights, a missing file — and the raw output
/// is then the explanation, which the caller shows. An empty string means the file really is empty:
/// the two must not collapse into each other.
String? parseSudoRead(String output) {
  final marker = '$sudoOutputMarker\n';
  final at = output.indexOf(marker);
  if (at < 0) return null;
  return output.substring(at + marker.length);
}

/// Output that means a privileged command was refused rather than run.
///
/// Ported from the marker list in `sftpReadError` (`ui/AppViewModel.kt:9678`). One list rather than
/// a copy per call site, because a marker added to one and not the other is a failure that stops
/// being reported on exactly one screen.
const List<String> sudoFailureMarkers = [
  'permission denied',
  'no such',
  'sudo:',
  'a password is required',
  'incorrect password',
  'not in the sudoers',
  'operation not permitted',
  'read-only file system',
];

/// True when [text] anywhere carries one of [sudoFailureMarkers].
bool hasSudoFailureMarker(String text) {
  final lower = text.toLowerCase();
  return sudoFailureMarkers.any(lower.contains);
}

/// The refusal a privileged search met, or null when it ran.
///
/// Needed because [remoteSearchCommand] sends `find`'s own errors to `/dev/null`: without this, a
/// search of a tree the login cannot read comes back empty and is reported as "nothing matched" —
/// a wrong answer wearing the clothes of a right one.
///
/// **A type-tagged line is a result, never a complaint.** Matching on the text alone would let a
/// file legitimately named `no such thing.txt` blank out the whole result set it appeared in, and
/// the first hit is exactly where that would bite. Anything sudo has to say arrives before the
/// command's output, so the first line settles it either way.
String? searchSudoFailure(String output) {
  for (final line in const LineSplitter().convert(output)) {
    if (line.trim().isEmpty) continue;
    if (line.startsWith('d\t') || line.startsWith('f\t')) return null;
    final trimmed = line.trim();
    return hasSudoFailureMarker(trimmed) ? trimmed : null;
  }
  return null;
}

/// Writes [content] to a protected path.
///
/// SFTP cannot write there either, so the file goes to a temp path the login *can* write, is copied
/// into place with sudo, and its size is read back as root. The temp copy is removed whether or not
/// the copy worked — leaving a readable copy of a protected file in `/tmp` would be a quiet way to
/// widen access to it.
String sudoWriteCommand(String tempPath, String destPath, String sudoPassword) => sudoShWrap(
  'cp -f -- ${shellQuote(tempPath)} ${shellQuote(destPath)} && '
  'wc -c < ${shellQuote(destPath)}; '
  'rm -f -- ${shellQuote(tempPath)}',
  sudoPassword,
);

/// The byte count [sudoWriteCommand] reported, or -1 when none came back.
///
/// The *last* numeric line, not the first: sudo's lecture and any warning come first, and a `wc`
/// count is the last thing the script prints. -1 means the write may still have happened but
/// nothing confirmed it, which `judgeSave` reports as unconfirmed rather than as success.
int parseSudoWriteSize(String output) {
  var size = -1;
  for (final line in const LineSplitter().convert(output)) {
    final parsed = int.tryParse(line.trim());
    if (parsed != null) size = parsed;
  }
  return size;
}

/// A temp path for the sudo write dance, in a directory any login can write.
String sudoTempPath() => '/tmp/.omniterm-save-${DateTime.now().microsecondsSinceEpoch}';

// ── crontab ────────────────────────────────────────────────────────────────────

/// Marks the end of `crontab -l`'s output so its exit status can be read.
const cronExitMarker = '---OMNITERM-CRON-EXIT---';

/// Reads the login user's crontab, **keeping the exit status and the error text**.
///
/// The Kotlin runs `crontab -l 2>/dev/null || true`, which collapses three very different answers
/// into one empty string: this user has no crontab, this user is not allowed one, and the command
/// does not exist on this host. That matters because the next thing the screen offers is *Add*, and
/// saving writes the **whole file** — so an unreadable crontab that reads as empty becomes a
/// crontab containing one line, with everything that was in it gone.
const crontabReadCommand = 'crontab -l 2>&1; printf "%s%s\\n" "$cronExitMarker" "\$?"';

/// What a crontab read actually found.
class CrontabRead {
  const CrontabRead(this.text, {required this.readable, this.error = ''});

  /// The crontab body. Empty when there is none, or when it could not be read.
  final String text;

  /// False when the host refused or could not answer. Editing must be disabled: writing a file we
  /// were not allowed to read would replace contents nobody has seen.
  final bool readable;

  /// Why it could not be read, for the screen to show verbatim.
  final String error;
}

/// Splits [output] into the crontab body and the fate of the command.
///
/// "no crontab for `<user>`" is cron's own way of saying the file is empty; every implementation
/// prints it on stderr and exits non-zero, so it has to be recognised or a first-time user could
/// never add an entry.
CrontabRead parseCrontabRead(String output) {
  final marker = output.lastIndexOf(cronExitMarker);
  if (marker < 0) {
    // No marker means the command never ran to completion — a dropped connection, or a shell that
    // died. Not an empty crontab.
    return CrontabRead(
      '',
      readable: false,
      error: output.trim().isEmpty ? 'No response' : output.trim(),
    );
  }

  final body = output.substring(0, marker);
  final status = int.tryParse(output.substring(marker + cronExitMarker.length).trim()) ?? -1;
  if (status == 0) {
    return CrontabRead(_stripTrailingNewline(body), readable: true);
  }

  if (RegExp(r'no crontab for', caseSensitive: false).hasMatch(body)) {
    return const CrontabRead('', readable: true);
  }
  return CrontabRead(
    '',
    readable: false,
    error: body.trim().isEmpty ? 'crontab exited $status' : body.trim(),
  );
}

String _stripTrailingNewline(String s) => s.endsWith('\n') ? s.substring(0, s.length - 1) : s;

/// Installs [text] as the login user's crontab.
///
/// Sent base64-encoded rather than as a here-doc or an echo chain: a crontab is full of `%`, `*`,
/// quotes and `$`, every one of which means something to the shell on the way in. Encoding it means
/// the bytes that arrive are the bytes that were typed. The three decoder spellings cover GNU,
/// BusyBox and BSD/macOS, which disagree on the flag.
String crontabWriteCommand(String text) {
  final normalised = '${text.trimRight()}\n';
  final encoded = base64.encode(utf8.encode(normalised));
  final decode =
      '{ printf %s ${shellQuote(encoded)} | base64 -d 2>/dev/null || '
      'printf %s ${shellQuote(encoded)} | base64 --decode 2>/dev/null || '
      'printf %s ${shellQuote(encoded)} | base64 -D; }';
  return '$decode | crontab - 2>&1';
}

/// Sentinel printed after a completed conflict scan.
///
/// Its absence means the script died part way — a truncated scan must never be read as "no
/// conflicts", which would turn a failed check into a silent overwrite.
const conflictScanOk = '@OMNITERM_CONFLICT_SCAN_OK';

/// Compares each of [sources] against the same basename inside [destDir].
///
/// Ported from `RemoteCommands.compareForConflicts` in `data/RemoteParsers.kt`.
///
/// Emits `sourceIndex<TAB>verdict<TAB>srcSize<TAB>dstSize<TAB>srcMtime<TAB>dstMtime` per conflict,
/// where verdict is IDENTICAL / DIFFERENT / DIR / UNKNOWN. **The index, not the basename, is the
/// key**: tabs and newlines are legal in filenames and would otherwise corrupt this line protocol.
///
/// Name, size and mtime together are only a heuristic — an rsync-style copy reproduces mtime
/// exactly, and two different files can share a size. So when sizes match both sides are hashed and
/// the digests compared; only then can "identical" be asserted. Differing sizes are decisive on
/// their own, so the potentially expensive hash is skipped. Directories report DIR because they
/// merge rather than replace. UNKNOWN means no hash tool was available, and the UI must treat the
/// pair as possibly-different rather than claiming a match.
String compareForConflicts(String destDir, List<String> sources) {
  if (sources.isEmpty) return '';
  final quotedDest = shellQuote(destDir);
  final out = StringBuffer()
    // Pick a digest tool once; an empty OT_H means "cannot hash" -> UNKNOWN, never a false match.
    ..write('OT_H=; for c in sha256sum shasum md5sum cksum; do ')
    ..write('command -v "\$c" >/dev/null 2>&1 && { OT_H="\$c"; break; }; done; ')
    ..write(
      "OT_STAT() { stat -c '%s %Y' \"\$1\" 2>/dev/null || stat -f '%z %m' \"\$1\" 2>/dev/null; }; ",
    );
  for (var index = 0; index < sources.length; index++) {
    out
      ..write('OT_S=${shellQuote(sources[index])}; ')
      ..write('OT_N=\$(basename "\$OT_S"); OT_D=$quotedDest/"\$OT_N"; ')
      ..write('if [ -e "\$OT_D" ]; then ')
      ..write('if [ -d "\$OT_S" ] || [ -d "\$OT_D" ]; then ')
      ..write("printf '$index\\tDIR\\t0\\t0\\t0\\t0\\n'; else ")
      ..write('set -- \$(OT_STAT "\$OT_S"); OT_SS=\${1:-0}; OT_SM=\${2:-0}; ')
      ..write('set -- \$(OT_STAT "\$OT_D"); OT_DS=\${1:-0}; OT_DM=\${2:-0}; ')
      ..write('if [ "\$OT_SS" != "\$OT_DS" ]; then OT_V=DIFFERENT; ')
      ..write('elif [ -z "\$OT_H" ]; then OT_V=UNKNOWN; ')
      ..write('else OT_A=\$("\$OT_H" "\$OT_S" 2>/dev/null | awk \'{print \$1}\'); ')
      ..write('OT_B=\$("\$OT_H" "\$OT_D" 2>/dev/null | awk \'{print \$1}\'); ')
      ..write('if [ -z "\$OT_A" ] || [ -z "\$OT_B" ]; then OT_V=UNKNOWN; ')
      ..write('elif [ "\$OT_A" = "\$OT_B" ]; then OT_V=IDENTICAL; else OT_V=DIFFERENT; fi; fi; ')
      ..write(
        "printf '$index\\t%s\\t%s\\t%s\\t%s\\t%s\\n' \"\$OT_V\" \"\$OT_SS\" \"\$OT_DS\" \"\$OT_SM\" \"\$OT_DM\"; ",
      )
      ..write('fi; fi; ');
  }
  out.write("printf '%s\\n' '$conflictScanOk'");
  return out.toString();
}

/// Whether tmux is on the host's PATH. Answers exactly `yes` or `no`.
///
/// Ported from `RemoteCommands.TMUX_CHECK` in `data/RemoteParsers.kt:140`.
const tmuxCheckCommand = 'command -v tmux >/dev/null 2>&1 && echo yes || echo no';

/// Installs tmux with whichever package manager the host has.
///
/// Ported verbatim from `RemoteCommands.tmuxInstallCommand()` in `data/RemoteParsers.kt:303`.
///
/// `sudo -S` reads the password from stdin, so the caller pairs this with [sudoStdin] — the password
/// never appears in the command line, where `ps` and auditd would see it. A host already running as
/// root skips sudo entirely rather than requiring it to be installed.
///
/// It re-checks at the end instead of trusting the package manager's exit code: several of these
/// return 0 for "nothing to do" on a broken mirror, and reporting a successful install of something
/// that is not there would send the user back to a non-resumable shell with no explanation.
String tmuxInstallCommand() =>
    "set -e; if command -v tmux >/dev/null 2>&1; then echo 'tmux already installed'; exit 0; fi; "
    'if [ "\$(id -u)" = 0 ]; then SUDO=; else SUDO=\'sudo -S\'; fi; '
    'if command -v apt-get >/dev/null 2>&1; then \$SUDO apt-get update && \$SUDO apt-get install -y tmux; '
    'elif command -v dnf >/dev/null 2>&1; then \$SUDO dnf install -y tmux; '
    'elif command -v yum >/dev/null 2>&1; then \$SUDO yum install -y tmux; '
    'elif command -v pacman >/dev/null 2>&1; then \$SUDO pacman -Sy --noconfirm tmux; '
    'elif command -v apk >/dev/null 2>&1; then \$SUDO apk add tmux; '
    'elif command -v zypper >/dev/null 2>&1; then \$SUDO zypper install -y tmux; '
    'elif command -v pkg >/dev/null 2>&1; then \$SUDO pkg install -y tmux; '
    "else echo 'No supported package manager found; install tmux manually.' >&2; exit 1; fi; "
    "command -v tmux >/dev/null 2>&1 && echo 'tmux installed' || { echo 'tmux install failed' >&2; exit 1; }";

/// The tmux session name reduced to what is safe to interpolate into a shell command.
///
/// Ported from the filter in `RemoteCommands.tmuxCaptureHistoryCommand` (`data/RemoteParsers.kt:281`).
/// The name travels inside a command string, so anything outside this set is dropped rather than
/// escaped; the fallback keeps a name that reduces to nothing from producing a bare `-t ` and a
/// syntax error.
String tmuxSafeSessionName(String name) {
  final safe = name.split('').where((c) => RegExp(r'[0-9A-Za-z-]').hasMatch(c)).join();
  return safe.isEmpty ? 'omniterm' : safe;
}

/// Reads a persistent pane's own scrollback — or nothing at all while a TUI owns the pane.
///
/// Active pane id of [name]'s current window, e.g. `%0`.
///
/// Ported from `RemoteCommands.tmuxActivePaneQuery` (`data/RemoteParsers.kt:202`). This is a **side
/// channel**, deliberately: control mode's own `%begin`…`%end` replies would work, but the query has
/// to be answerable while the control stream is mid-burst, and an exec channel cannot be starved by
/// pane output the way the control conversation can.
String tmuxActivePaneQuery(String name) =>
    "tmux display-message -p -t ${tmuxSafeSessionName(name)} '#{pane_id}' 2>/dev/null || true";

/// Ported from `RemoteCommands.tmuxCaptureHistoryCommand` (`data/RemoteParsers.kt:280`).
///
/// tmux does not stream every line to an attached client: output faster than the client consumes is
/// collapsed into a screen repaint, so rows the user never had on screen are simply missing from
/// locally captured scrollback. The pane's real history lives on the server, and this is how it is
/// fetched.
///
/// The `#{alternate_on}` test is why this is a shell conditional and not a bare `capture-pane`.
/// While a full-screen TUI owns the pane's alternate screen, `capture-pane` returns the TUI's frames
/// rather than the primary screen's history — verified against tmux 3.3a — and adopting those would
/// replace real history with `vim` repaints. Producing **empty output** in that case is deliberate:
/// the caller keeps its dirty flag armed and retries once the TUI exits.
String tmuxCaptureHistoryCommand(String name, int maxLines) {
  final safe = tmuxSafeSessionName(name);
  final lines = maxLines.clamp(1000, 50000);
  return 'if [ "\$(tmux display-message -p -t $safe \'#{alternate_on}\' 2>/dev/null)" = 1 ]; '
      'then :; else tmux capture-pane -p -e -J -S -$lines -E -1 -t $safe 2>/dev/null; fi || true';
}
