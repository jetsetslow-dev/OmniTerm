/// Parsers for live SSH command output, ported from the `RemoteParsers` object in
/// `data/RemoteParsers.kt`.
///
/// Everything here is pure: `String in, model out`, no I/O and no platform dependency. That is what
/// makes it portable to iOS unchanged, and what lets the Kotlin unit tests come across as Dart
/// tests almost verbatim.
///
/// The tolerance for malformed input is deliberate throughout. These parse the output of whatever
/// `ps`/`df`/`top`/`docker` happens to exist on an arbitrary remote host — BusyBox, GNU, BSD,
/// PowerShell — so a line that does not fit the expected shape is skipped rather than thrown on. A
/// poll that throws would blank the whole Monitor screen; a poll that skips one line shows the rest.
library;

import 'dart:math' as math;

import 'kotlin_strings.dart';
import 'remote_commands.dart';
import 'remote_models.dart';

/// Output of `RemoteCommands.DOCKER_RUNTIMES`: one runtime name per line, anything else ignored.
Set<String> parseRuntimeList(String output) =>
    output.lines.map((l) => l.trim()).where((l) => l == 'docker' || l == 'podman').toSet();

/// The directory compose actions `cd` into for a stack.
///
/// Prefers the working_dir label; when a runtime sets config_files but not working_dir
/// (podman-compose, notably), falls back to the parent directory of the first absolute config file
/// — the directory compose would use anyway. Blank when neither yields a usable absolute directory.
String composeStackWorkingDir(String workingDirLabel, String configFiles) {
  if (!workingDirLabel.isBlankString) return workingDirLabel;
  final firstConfig =
      configFiles.split(',').map((s) => s.trim()).where((s) => s.isNotEmpty).firstOrNull ?? '';
  if (!firstConfig.startsWith('/')) return '';
  return firstConfig.substringBeforeLast('/').ifEmpty('/');
}

/// Columns: `pid user %cpu %mem vsz etime stat comm` (Linux/BSD/macOS and the Windows emulation),
/// or BusyBox's plain `ps w` 4-column form (PID USER TIME COMMAND) from the fallback path.
///
/// The `ps` header line is skipped because its first column ("PID") isn't an integer.
List<SimProcess> parseProcesses(String output) {
  final out = <SimProcess>[];
  for (final raw in output.lines) {
    final line = raw.trim();
    if (line.isEmpty) continue;
    final t = splitWhitespace(line, limit: 8);
    final pid = int.tryParse(t.getOrElse(0, ''));
    if (pid == null) continue;

    if (t.length >= 8) {
      out.add(
        SimProcess(
          pid: pid,
          owner: t[1],
          cpu: double.tryParse(t[2]) ?? 0,
          mem: double.tryParse(t[3]) ?? 0,
          vms: humanBytes((int.tryParse(t[4]) ?? 0) * 1024),
          uptime: t[5],
          state: t[6].takeChars(1),
          name: t[7],
        ),
      );
    } else if (t.length >= 4) {
      // BusyBox: no per-process cpu/mem/vsz; TIME stands in for uptime and the command may itself
      // contain spaces (re-join the split tail).
      out.add(
        SimProcess(
          pid: pid,
          owner: t[1],
          cpu: 0,
          mem: 0,
          vms: '—',
          uptime: t[2],
          state: '',
          name: t.skip(3).join(' '),
        ),
      );
    }
  }
  return out;
}

/// OpenRC `rc-status -a` line: "  sshd  [  started  ]" (runlevel headers don't match).
final _openrcServiceRe = RegExp(r'^(\S+)\s*\[\s*(\w+)\s*]');

List<SimService> parseServices(String output) {
  if (output.contains('---OPENRC---')) {
    final out = <SimService>[];
    for (final raw in output.substringAfter('---OPENRC---').lines) {
      final m = _openrcServiceRe.firstMatch(raw.trim());
      if (m == null) continue;
      final state = m.group(2)!.toLowerCase();
      out.add(
        SimService(
          name: m.group(1)!,
          desc: 'OpenRC service',
          status: switch (state) {
            'started' => 'running',
            'crashed' => 'failed',
            _ => 'dead',
          },
          subState: state,
          // rc-status -a lists services attached to runlevels, which is OpenRC's closest notion of
          // "enabled".
          enabled: true,
        ),
      );
    }
    return out;
  }

  final sections = output.split('---ENABLED---');
  final unitsSection = sections[0];
  final enabledSection = sections.getOrElse(1, '');

  // Build enabled-state map from the unit-files section: unit.service -> state.
  final enabledMap = <String, String>{};
  for (final raw in enabledSection.lines) {
    final line = raw.trim();
    if (line.isEmpty) continue;
    final t = splitWhitespace(line, limit: 2);
    if (t.length < 2) continue;
    enabledMap[t[0]] = t[1].trim();
  }

  final out = <SimService>[];
  for (final raw in unitsSection.lines) {
    final line0 = raw.trim();
    if (line0.isEmpty) continue;
    // Some systemd builds prefix a "●"/"*" status bullet even with --plain; strip it.
    final line = line0.removePrefix('●').removePrefix('*').trim();
    final t = splitWhitespace(line, limit: 5);
    if (t.length < 4) continue;
    final unit = t[0];
    if (!unit.endsWith('.service')) continue;
    final active = t[2];
    final sub = t[3];
    final enableState = enabledMap[unit] ?? '';
    out.add(
      SimService(
        name: unit.removeSuffix('.service'),
        desc: t.getOrNull(4)?.trim() ?? '',
        status: switch (active) {
          'active' => 'running',
          'failed' => 'failed',
          _ => 'dead',
        },
        subState: (active == 'failed' || sub == 'failed')
            ? 'failed'
            : (active == 'active' ? 'active' : sub),
        enabled: enableState.startsWith('enabled'),
      ),
    );
  }
  return out;
}

final _journalRe = RegExp(r'^(\S+)\s+(\S+)\s+([^:]+?):\s?(.*)$');

/// True when the host exposes no readable log source, so the UI can explain rather than show empty.
bool journalUnsupported(String output) => output.contains('---NOLOGS---');

/// Parse `RemoteCommands.compareForConflicts` output.
///
/// Anything unrecognised maps to [ConflictVerdict.unknown] rather than being dropped or assumed
/// benign: a clash we failed to classify must still be shown to the user as unverified, never
/// silently treated as identical.
List<TransferConflict> parseTransferConflicts(String output) {
  final out = <TransferConflict>[];
  for (final raw in output.lines) {
    final line = raw.trim();
    if (line.isEmpty || !line.contains('\t')) continue;
    final f = line.split('\t');
    if (f.length < 6) continue;
    final name = f[0];
    if (name.isBlankString) continue;

    final verdict = switch (f[1].toUpperCase()) {
      'IDENTICAL' => ConflictVerdict.identical,
      'DIFFERENT' => ConflictVerdict.different,
      'DIR' => ConflictVerdict.directory,
      _ => ConflictVerdict.unknown,
    };
    out.add(
      TransferConflict(
        name: name,
        verdict: verdict,
        sourceSize: int.tryParse(f[2]) ?? 0,
        destSize: int.tryParse(f[3]) ?? 0,
        sourceMtimeSeconds: int.tryParse(f[4]) ?? 0,
        destMtimeSeconds: int.tryParse(f[5]) ?? 0,
        // Default the safe way round: only a proven-identical pair is pre-set to overwrite (it
        // destroys nothing). Everything else defaults to Keep both.
        action: verdict == ConflictVerdict.identical
            ? ConflictAction.overwrite
            : ConflictAction.keepBoth,
      ),
    );
  }
  return out;
}

List<SimLog> parseJournal(String output) {
  final out = <SimLog>[];
  for (final raw in output.lines) {
    final line = raw.trim();
    // Skip "-- Logs begin --" banners and the no-log-source marker.
    if (line.isEmpty || line.startsWith('--') || line == '---NOLOGS---') continue;

    final m = _journalRe.firstMatch(line);
    final timeRaw = m != null ? m.group(1)! : '';
    final ident = m != null ? m.group(3)! : '';
    final msg = m != null ? m.group(4)! : line;

    final source = ident.substringBefore('[').trim().ifEmpty('system');
    out.add(
      SimLog(
        time: _extractTime(timeRaw),
        level: _inferLevel('$ident $msg'),
        source: source,
        message: msg,
      ),
    );
  }
  return out;
}

List<FleetLogEntry> parseFleetJournal(String output, String serverName, int serverId) =>
    parseJournal(output)
        .map(
          (log) => FleetLogEntry(
            serverName: serverName,
            serverId: serverId,
            timestamp: log.time,
            level: log.level,
            message: (!log.source.isBlankString && log.source != 'system')
                ? '[${log.source}] ${log.message}'
                : log.message,
          ),
        )
        .toList();

final _healthRe = RegExp(r'\((healthy|unhealthy|starting)\)', caseSensitive: false);

/// A cell that a runtime may fill with the literal `<no value>` when a label is absent.
String _labelCell(List<String> t, int index) {
  final v = t.getOrElse(index, '').trim();
  return v == '<no value>' ? '' : v;
}

List<SimContainer> parseDockerPs(String output) {
  final out = <SimContainer>[];
  for (final line in output.lines.map((l) => l.trimRight())) {
    if (line.isBlankString || line.startsWith('SSH Error')) continue;
    final raw = line.split('\t');
    if (raw.length < 4) continue;

    // Podman output is prefixed with its runtime name so a host running both can be told apart.
    final hasRuntimePrefix = raw.first == 'docker' || raw.first == 'podman';
    final runtime = hasRuntimePrefix ? raw.first : 'docker';
    final t = hasRuntimePrefix ? raw.sublist(1) : raw;

    final statusRaw = t[3].trim();
    final health = _healthRe.firstMatch(statusRaw)?.group(1)?.toLowerCase() ?? 'none';
    final statusLower = statusRaw.toLowerCase();

    out.add(
      SimContainer(
        id: t[0].takeChars(12),
        name: t.getOrElse(1, '').trim().removePrefix('/'),
        image: t.getOrElse(2, ''),
        status: switch (statusLower) {
          // A paused container reports e.g. "Up 3 hours (Paused)".
          _ when statusLower.contains('paused') => 'paused',
          _ when statusLower == 'running' || statusLower.startsWith('up') => 'running',
          _ when statusLower.startsWith('restarting') => 'restarting',
          _ when statusLower.startsWith('exited') => 'exited',
          _ => statusRaw.ifBlank('exited'),
        },
        health: health,
        ports: t.getOrElse(4, '').ifBlank('—'),
        group: _labelCell(t, 5).ifEmpty('standalone'),
        host: '',
        composeService: _labelCell(t, 6),
        composeWorkingDir: _labelCell(t, 7),
        composeConfigFiles: _labelCell(t, 8),
        restartCount: 0,
        createdAt: t.getOrElse(9, '').trim(),
        runtime: runtime,
      ),
    );
  }
  return out;
}

Map<String, int> parseDockerRestartCounts(String output) {
  final out = <String, int>{};
  for (final raw in output.lines) {
    final line = raw.trim();
    if (line.isEmpty || !line.contains('\t')) continue;
    final t = line.split('\t');
    if (t.length >= 3 && (t[0] == 'docker' || t[0] == 'podman')) {
      out['${t[0]}:${t[1].takeChars(12)}'] = int.tryParse(t[2]) ?? 0;
    } else {
      final first = t.getOrNull(0);
      if (first == null) continue;
      out[first.takeChars(12)] = int.tryParse(t.getOrElse(1, '')) ?? 0;
    }
  }
  return out;
}

List<SimDockerImage> parseDockerImages(String output) {
  final out = <SimDockerImage>[];
  for (final line in output.lines.map((l) => l.trimRight())) {
    if (line.isBlankString || line.startsWith('SSH Error')) continue;
    final raw = line.split('\t');
    if (raw.length < 5) continue;
    final hasRuntimePrefix = raw.first == 'docker' || raw.first == 'podman';
    final runtime = hasRuntimePrefix ? raw.first : 'docker';
    final t = hasRuntimePrefix ? raw.sublist(1) : raw;
    out.add(
      SimDockerImage(
        id: t[0].removePrefix('sha256:').takeChars(12),
        repository: t[1],
        tag: t[2],
        size: t[3],
        created: t[4],
        runtime: runtime,
      ),
    );
  }
  return out;
}

List<SimDockerVolume> parseDockerVolumes(String output) {
  final out = <SimDockerVolume>[];
  for (final line in output.lines.map((l) => l.trimRight())) {
    if (line.isBlankString || line.startsWith('SSH Error')) continue;
    final raw = line.split('\t');
    if (raw.length < 2) continue;
    final hasRuntimePrefix = raw.first == 'docker' || raw.first == 'podman';
    final runtime = hasRuntimePrefix ? raw.first : 'docker';
    final t = hasRuntimePrefix ? raw.sublist(1) : raw;
    final links = int.tryParse(t.getOrElse(4, '0')) ?? 0;
    out.add(
      SimDockerVolume(
        name: t[0],
        driver: t[1],
        mountpoint: t.getOrElse(2, ''),
        size: t.getOrElse(3, ''),
        inUse: links > 0,
        runtime: runtime,
      ),
    );
  }
  return out;
}

List<SimDockerNetwork> parseDockerNetworks(String output) {
  final out = <SimDockerNetwork>[];
  for (final raw in output.lines) {
    final line = raw.trim();
    if (line.isEmpty || line.startsWith('NETWORK')) continue;
    final cells = line.split('\t');
    if (cells.length < 3) continue;
    final hasRuntimePrefix = cells.first == 'docker' || cells.first == 'podman';
    final runtime = hasRuntimePrefix ? cells.first : 'docker';
    final t = hasRuntimePrefix ? cells.sublist(1) : cells;
    out.add(SimDockerNetwork(id: t[0].takeChars(12), name: t[1], driver: t[2], runtime: runtime));
  }
  return out;
}

/// Dispatch host-metrics parsing by the detected remote OS (from the `@OS` section).
HostMetrics parseMetrics(String output, {String host = ''}) {
  final sections = _splitSections(output);
  return switch (normaliseOs(sections['OS'] ?? '')) {
    'FreeBSD' => _parseMetricsBsd(sections, 'FreeBSD'),
    'Darwin' => _parseMetricsDarwin(sections),
    'Windows' => _parseMetricsWindows(sections),
    _ => _parseMetricsLinux(sections),
  };
}

final _linuxIdleRe = RegExp(r'([\d.]+)\s*%?\s*id');
final _bsdIdleRe = RegExp(r'([\d.]+)%\s*idle', caseSensitive: false);

HostMetrics _parseMetricsLinux(Map<String, String> sections) {
  // CPU idle: GNU top "95.6 id" or BusyBox top "98% idle" → 100 - idle.
  var cpu = 0.0;
  final cpuSection = sections['CPU'];
  if (cpuSection != null) {
    final idle = double.tryParse(_linuxIdleRe.firstMatch(cpuSection)?.group(1) ?? '');
    if (idle != null) cpu = (100 - idle).clamp(0, 100).toDouble();
  }

  // MEM (free -b): "Mem:  total used free shared buff/cache available".
  var memTotal = 0;
  var memUsed = 0;
  final memSection = sections['MEM']?.trim();
  if (memSection != null && memSection.isNotEmpty) {
    final t = splitWhitespace(memSection);
    memTotal = int.tryParse(t.getOrElse(1, '')) ?? 0;
    final available = int.tryParse(t.getOrElse(6, ''));
    memUsed = available != null
        ? math.max(0, memTotal - available)
        : (int.tryParse(t.getOrElse(2, '')) ?? 0);
  }
  // Fall back to /proc/meminfo (values in kB) when `free` was unavailable/oddly-shaped (common on
  // BusyBox/Alpine), so we don't silently report 0% memory.
  if (memTotal == 0) {
    final info = sections['MEMINFO'] ?? '';
    int? kb(String field) => int.tryParse(
      RegExp('$field:\\s+(\\d+)\\s*kB', caseSensitive: false).firstMatch(info)?.group(1) ?? '',
    );
    final totalKb = kb('MemTotal');
    if (totalKb != null) {
      memTotal = totalKb * 1024;
      final availKb = kb('MemAvailable') ?? kb('MemFree');
      memUsed = availKb != null ? math.max(0, (totalKb - availKb) * 1024) : 0;
    }
  }

  // DISK (df -PB1 /): "fs total used avail use% /". A leading KB1024 token marks the BusyBox
  // `df -Pk` fallback, whose sizes are 1024-byte blocks.
  var diskTotal = 0;
  var diskUsed = 0;
  final diskSection = sections['DISK']?.trim();
  if (diskSection != null) {
    final rawCells = splitWhitespace(diskSection);
    final kb = rawCells.firstOrNull == 'KB1024';
    final t = kb ? rawCells.sublist(1) : rawCells;
    final scale = kb ? 1024 : 1;
    diskTotal = (int.tryParse(t.getOrElse(1, '')) ?? 0) * scale;
    diskUsed = (int.tryParse(t.getOrElse(2, '')) ?? 0) * scale;
  }

  // LOAD: "0.08 0.11 0.09 1/297 1234".
  var l1 = 0.0, l5 = 0.0, l15 = 0.0;
  var procs = 0;
  final loadSection = sections['LOAD']?.trim();
  if (loadSection != null) {
    final t = splitWhitespace(loadSection);
    l1 = double.tryParse(t.getOrElse(0, '')) ?? 0;
    l5 = double.tryParse(t.getOrElse(1, '')) ?? 0;
    l15 = double.tryParse(t.getOrElse(2, '')) ?? 0;
    procs = int.tryParse(t.getOrElse(3, '').substringAfter('/', '')) ?? 0;
  }

  final uptime =
      double.tryParse(splitWhitespace(sections['UP']?.trim() ?? '').getOrElse(0, ''))?.toInt() ?? 0;

  final procFromSection = int.tryParse(sections['PROC']?.trim() ?? '');
  final procCount = (procFromSection != null && procFromSection > 0) ? procFromSection : procs;

  // CPU temperature: hottest thermal zone, reported in millidegrees Celsius.
  double? cpuTempC;
  final temps = (sections['TEMP'] ?? '').lines
      .map((l) => int.tryParse(l.trim()))
      .whereType<int>()
      .toList();
  if (temps.isNotEmpty) {
    final hottest = temps.reduce((a, b) => a > b ? a : b);
    final celsius = hottest > 1000 ? hottest / 1000 : hottest.toDouble();
    if (celsius > 0) cpuTempC = celsius;
  }

  final tcpConnections =
      int.tryParse((sections['TCP']?.trim() ?? '').lines.lastOrNull?.trim() ?? '') ?? 0;

  // Attach SMART health to each mount by matching its block device (strip /dev/ and partition).
  final smart = parseSmart(sections['SMART'] ?? '');
  final disks = parseDisks(sections['DISKS'] ?? '').map((d) {
    final dev = d.filesystem.removePrefix('/dev/').replaceAll(RegExp(r'p?\d+$'), '');
    return d.copyWith(health: smart[dev] ?? '');
  }).toList();

  // Prefer the distro pretty-name (Raspberry Pi OS, Ubuntu 22.04, Alpine, …) over bare "Linux".
  final distro = (sections['DISTRO']?.trim() ?? '').lines
      .where((l) => !l.isBlankString)
      .firstOrNull
      ?.trim();
  final osLabel = (distro == null || distro.isEmpty) ? 'Linux' : distro;

  final platforms =
      (sections['PLATFORM'] ?? '').lines.map((l) => l.trim()).where((l) => l.isNotEmpty).toSet()
        ..add('linux');

  return HostMetrics(
    cpuPercent: cpu,
    memUsedBytes: memUsed,
    memTotalBytes: memTotal,
    diskUsedBytes: diskUsed,
    diskTotalBytes: diskTotal,
    load1: l1,
    load5: l5,
    load15: l15,
    uptimeSeconds: uptime,
    procCount: procCount,
    cpuTempC: cpuTempC,
    tcpConnections: tcpConnections,
    disks: disks,
    os: osLabel,
    platforms: platforms,
  );
}

/// FreeBSD/OpenBSD metrics (sysctl/df -k/netstat). Per-core/temp/disk-I/O/SMART are not collected.
HostMetrics _parseMetricsBsd(Map<String, String> sections, String os) {
  var cpu = 0.0;
  final cpuSection = sections['CPU'];
  if (cpuSection != null) {
    final idle = double.tryParse(_bsdIdleRe.firstMatch(cpuSection)?.group(1) ?? '');
    if (idle != null) cpu = (100 - idle).clamp(0, 100).toDouble();
  }

  final mem = sections['SYSMEM'] ?? '';
  int sm(String key) =>
      int.tryParse(RegExp('^$key\\s+(\\d+)', multiLine: true).firstMatch(mem)?.group(1) ?? '') ?? 0;
  final pageSizeRaw = sm('pagesize');
  final pageSize = pageSizeRaw > 0 ? pageSizeRaw : 4096;
  final memTotal = sm('phys');
  final freeBytes = (sm('free') + sm('inactive') + sm('cache')) * pageSize;
  final memUsed = math.max(0, memTotal - freeBytes);

  final disks = parseDisks(sections['DISKS'] ?? '', blockBytes: 1024);
  final root = disks.where((d) => d.mount == '/').firstOrNull;
  final load = _loadAverages(sections['LOADAVG'] ?? '');
  final uptime = _bsdUptime(sections);

  return HostMetrics(
    cpuPercent: cpu,
    memUsedBytes: memUsed,
    memTotalBytes: memTotal,
    diskUsedBytes: root?.usedBytes ?? 0,
    diskTotalBytes: root?.totalBytes ?? 0,
    load1: load.getOrElse(0, 0),
    load5: load.getOrElse(1, 0),
    load15: load.getOrElse(2, 0),
    uptimeSeconds: uptime,
    procCount: int.tryParse(sections['PROC']?.trim() ?? '') ?? 0,
    tcpConnections: int.tryParse(sections['TCP']?.trim() ?? '') ?? 0,
    disks: disks,
    netInterfaces: _parseBsdNetstat(sections['NETSTAT'] ?? ''),
    os: os,
    platforms: const {'freebsd'},
  );
}

/// macOS metrics: like BSD but memory from `vm_stat` + `hw.memsize`.
HostMetrics _parseMetricsDarwin(Map<String, String> sections) {
  var cpu = 0.0;
  final cpuSection = sections['CPU'];
  if (cpuSection != null) {
    final idle = double.tryParse(_bsdIdleRe.firstMatch(cpuSection)?.group(1) ?? '');
    if (idle != null) cpu = (100 - idle).clamp(0, 100).toDouble();
  }

  final memTotal = int.tryParse(sections['MEMSIZE']?.trim() ?? '') ?? 0;
  final vmstat = sections['VMSTAT'] ?? '';
  final pageSize =
      int.tryParse(RegExp(r'page size of (\d+) bytes').firstMatch(vmstat)?.group(1) ?? '') ?? 4096;
  int pages(String label) =>
      int.tryParse(RegExp('$label:\\s+(\\d+)').firstMatch(vmstat)?.group(1) ?? '') ?? 0;
  final freeBytes =
      (pages('Pages free') + pages('Pages inactive') + pages('Pages speculative')) * pageSize;
  final memUsed = math.max(0, memTotal - freeBytes);

  final disks = parseDisks(sections['DISKS'] ?? '', blockBytes: 1024);
  final root = disks.where((d) => d.mount == '/').firstOrNull;
  final load = _loadAverages(sections['LOADAVG'] ?? '');

  return HostMetrics(
    cpuPercent: cpu,
    memUsedBytes: memUsed,
    memTotalBytes: memTotal,
    diskUsedBytes: root?.usedBytes ?? 0,
    diskTotalBytes: root?.totalBytes ?? 0,
    load1: load.getOrElse(0, 0),
    load5: load.getOrElse(1, 0),
    load15: load.getOrElse(2, 0),
    uptimeSeconds: _bsdUptime(sections),
    procCount: int.tryParse(sections['PROC']?.trim() ?? '') ?? 0,
    tcpConnections: int.tryParse(sections['TCP']?.trim() ?? '') ?? 0,
    disks: disks,
    netInterfaces: _parseBsdNetstat(sections['NETSTAT'] ?? ''),
    os: 'Darwin',
    platforms: const {'darwin'},
  );
}

/// Windows (PowerShell) best-effort: CPU load %, memory, logical disks, uptime, proc count.
HostMetrics _parseMetricsWindows(Map<String, String> sections) {
  final cpu =
      (double.tryParse((sections['WINCPU']?.trim() ?? '').lines.firstOrNull?.trim() ?? '') ?? 0)
          .clamp(0, 100)
          .toDouble();

  var memTotal = 0;
  var memUsed = 0;
  final winmem = sections['WINMEM']?.trim();
  if (winmem != null) {
    final t = splitWhitespace(winmem);
    memTotal = int.tryParse(t.getOrElse(0, '')) ?? 0;
    final free = int.tryParse(t.getOrElse(1, '')) ?? 0;
    memUsed = math.max(0, memTotal - free);
  }

  final disks = <DiskUsage>[];
  for (final line in (sections['WINDISK'] ?? '').lines) {
    final t = splitWhitespace(line.trim());
    if (t.length < 3) continue;
    final total = int.tryParse(t[1]);
    if (total == null || total <= 0) continue;
    final free = int.tryParse(t[2]) ?? 0;
    disks.add(
      DiskUsage(
        mount: t[0],
        filesystem: t[0],
        totalBytes: total,
        usedBytes: math.max(0, total - free),
      ),
    );
  }
  final root = disks.firstOrNull;

  return HostMetrics(
    cpuPercent: cpu,
    memUsedBytes: memUsed,
    memTotalBytes: memTotal,
    diskUsedBytes: root?.usedBytes ?? 0,
    diskTotalBytes: root?.totalBytes ?? 0,
    load1: 0,
    load5: 0,
    load15: 0,
    uptimeSeconds:
        double.tryParse(
          (sections['WINUP']?.trim() ?? '').lines.firstOrNull?.trim() ?? '',
        )?.toInt() ??
        0,
    procCount:
        int.tryParse((sections['WINPROC']?.trim() ?? '').lines.lastOrNull?.trim() ?? '') ?? 0,
    disks: disks,
    os: 'Windows',
    platforms: const {'windows'},
  );
}

List<double> _loadAverages(String section) =>
    RegExp(r'[\d.]+').allMatches(section).map((m) => double.parse(m.group(0)!)).toList();

/// Uptime as `now - kern.boottime`, both of which the BSD/macOS probe reports separately.
int _bsdUptime(Map<String, String> sections) {
  final boot = int.tryParse(
    RegExp(r'sec\s*=\s*(\d+)').firstMatch(sections['BOOT'] ?? '')?.group(1) ?? '',
  );
  final now = int.tryParse(sections['NOW']?.trim() ?? '');
  if (boot == null || now == null) return 0;
  final delta = now - boot;
  return delta < 0 ? 0 : delta;
}

/// Parse `netstat -ibn` (BSD/macOS) into per-interface RX/TX byte totals (first row per iface).
List<NetInterface> _parseBsdNetstat(String output) {
  final map = <String, NetInterface>{};
  for (final line in output.lines) {
    final t = splitWhitespace(line.trim());
    if (t.length < 11) continue;
    final name = t[0];
    if (name == 'Name' || name == 'lo0' || map.containsKey(name)) continue;
    // netstat -ibn: Name Mtu Network Address Ipkts Ierrs Idrop Ibytes Opkts Oerrs Obytes ...
    final rx = int.tryParse(t[7]);
    final tx = int.tryParse(t[10]);
    if (rx == null || tx == null) continue;
    map[name] = NetInterface(name, rx, tx);
  }
  return map.values.toList();
}

/// SMART health lines `<device>\t<health>` → device -> health.
Map<String, String> parseSmart(String output) {
  final map = <String, String>{};
  for (final line in output.lines) {
    final t = line.split('\t');
    if (t.length < 2) continue;
    final dev = t[0].trim();
    final health = t[1].trim();
    if (dev.isEmpty || health.isEmpty) continue;
    map[dev] = health;
  }
  return map;
}

final _wholeDiskRe = RegExp(r'^(sd[a-z]+|nvme\d+n\d+|vd[a-z]+|xvd[a-z]+|mmcblk\d+|hd[a-z]+)$');

/// Per-whole-disk cumulative read/write bytes from /proc/diskstats (sectors are 512 bytes).
Map<String, DiskIo> parseDiskIo(String output) {
  final map = <String, DiskIo>{};
  for (final line in output.lines) {
    final t = splitWhitespace(line.trim());
    if (t.length < 10) continue;
    final name = t[2];
    if (!_wholeDiskRe.hasMatch(name)) continue;
    map[name] = DiskIo(name, (int.tryParse(t[5]) ?? 0) * 512, (int.tryParse(t[9]) ?? 0) * 512);
  }
  return map;
}

/// Pseudo / virtual filesystems we don't want to show as "disks".
const _pseudoFs = <String>{
  'tmpfs',
  'devtmpfs',
  'overlay',
  'squashfs',
  'proc',
  'sysfs',
  'cgroup',
  'cgroup2',
  'devfs',
  'fdescfs',
  'procfs',
  'none',
  'udev',
  'ramfs',
  'efivarfs',
  'shm',
  'mqueue',
};

/// Parse `df` (all mounts) into per-partition usage, excluding pseudo filesystems.
///
/// [blockBytes] scales the size columns: 1 for `df -PB1` (Linux, already bytes), 1024 for `df -k`
/// (BSD/macOS).
List<DiskUsage> parseDisks(String output, {int blockBytes = 1}) {
  final out = <DiskUsage>[];
  for (final rawLine in output.lines) {
    final line = rawLine.trim();
    if (line.isEmpty) continue;

    // A line-leading KB1024 token marks the BusyBox `df -Pk` fallback (1024-byte blocks).
    final raw = splitWhitespace(line);
    final kb = raw.firstOrNull == 'KB1024';
    final t = kb ? raw.sublist(1) : raw;
    if (t.length < 6) continue;

    final fs = t[0];
    if (_pseudoFs.any((p) => fs.toLowerCase() == p)) continue;
    final total = int.tryParse(t[1]);
    if (total == null || total <= 0) continue;
    final used = int.tryParse(t[2]) ?? 0;
    final mount = t.sublist(5).join(' ');
    if (mount.startsWith('/proc') ||
        mount.startsWith('/sys') ||
        mount.startsWith('/dev') ||
        mount.startsWith('/run')) {
      continue;
    }
    out.add(
      DiskUsage(
        mount: mount,
        filesystem: fs,
        totalBytes: total * blockBytes,
        usedBytes: used * blockBytes,
      ),
    );
  }
  return out.distinctBy((d) => d.mount);
}

/// Per-CPU jiffies from /proc/stat: name -> (idleJiffies, totalJiffies). Used to derive rates.
Map<String, (int idle, int total)> parseProcStat(String output) {
  final map = <String, (int, int)>{};
  for (final line in output.lines) {
    final t = splitWhitespace(line.trim());
    if (t.length < 5 || !t[0].startsWith('cpu')) continue;
    final nums = t.skip(1).map(int.tryParse).whereType<int>().toList();
    if (nums.length < 4) continue;
    final idle = nums[3] + (nums.getOrNull(4) ?? 0); // idle + iowait
    final total = nums.fold<int>(0, (a, b) => a + b);
    map[t[0]] = (idle, total);
  }
  return map;
}

/// Busy percentage for one CPU between two /proc/stat samples, or null when there is no baseline.
double? computeCpuUsageDelta(
  Map<String, (int idle, int total)>? prev,
  Map<String, (int idle, int total)> cur,
  String cpuName,
) {
  if (prev == null) return null;
  final p = prev[cpuName];
  final c = cur[cpuName];
  if (p == null || c == null) return null;
  final idleDelta = (c.$1 - p.$1).toDouble();
  final totalDelta = (c.$2 - p.$2).toDouble();
  if (totalDelta <= 0) return 0;
  return ((1 - idleDelta / totalDelta) * 100).clamp(0, 100).toDouble();
}

List<double> computePerCoreCpuDeltas(
  Map<String, (int idle, int total)>? prev,
  Map<String, (int idle, int total)> cur,
) {
  if (prev == null) return const [];
  final cores = cur.keys.where((k) => k != 'cpu' && k.startsWith('cpu')).toList()
    ..sort(
      (a, b) => (int.tryParse(a.removePrefix('cpu')) ?? 0).compareTo(
        int.tryParse(b.removePrefix('cpu')) ?? 0,
      ),
    );
  return cores.map((c) => computeCpuUsageDelta(prev, cur, c) ?? 0).toList();
}

/// Per-interface cumulative RX/TX bytes from /proc/net/dev.
Map<String, (int rx, int tx)> parseNetDev(String output) {
  final map = <String, (int, int)>{};
  for (final line in output.lines) {
    final colon = line.indexOf(':');
    if (colon < 0) continue;
    final name = line.substring(0, colon).trim();
    if (name.isEmpty || name == 'lo') continue;
    final nums = splitWhitespace(
      line.substring(colon + 1).trim(),
    ).map(int.tryParse).whereType<int>().toList();
    if (nums.length < 9) continue;
    map[name] = (nums[0], nums[8]); // rxBytes, txBytes
  }
  return map;
}

// ── helpers ──

/// Splits a probe response into its `@SECTION` blocks.
Map<String, String> _splitSections(String output) {
  final map = <String, String>{};
  String? key;
  final sb = StringBuffer();
  void flush() {
    final k = key;
    if (k != null) map[k] = sb.toString().trim();
  }

  for (final line in output.lines) {
    if (line.startsWith('@')) {
      flush();
      sb.clear();
      key = line.substring(1).trim();
    } else {
      sb.writeln(line);
    }
  }
  flush();
  return map;
}

/// "2026-05-30T10:41:22+0530" → "10:41:22"; falls back to the raw prefix.
String _extractTime(String ts) {
  final afterT = ts.substringAfter('T');
  final m = RegExp(r'(\d{2}:\d{2}:\d{2})').firstMatch(afterT);
  return m?.group(1) ?? afterT.takeChars(8);
}

/// Severity vocabulary, matched as **word-initial stems** rather than whole words.
///
/// The Kotlin originals were `\b(...)\b`, and the trailing `\b` silently disabled every stem in
/// both lists: "fail" could not match "failure" or "failing", "error" could not match "errors", and
/// "deprecat" — obviously written as a stem — could only ever match the bare string "deprecat". In
/// the shipped app "connection failure", "disk errors detected" and "deprecated option in use" are
/// therefore all classified INFO, which is exactly backwards for log triage.
///
/// Dropping the trailing boundary fixes all of them at once. The leading `\b` is kept, so a stem
/// still has to start a word and cannot match mid-token. See MIGRATION.md §7.8.
final _errorRe = RegExp(r'\b(error|fail|fatal|critical|denied|refused|panic|segfault)');
final _warnRe = RegExp(r'\b(warn|deprecat|timeout|retry)');

String _inferLevel(String text) {
  final l = text.toLowerCase();
  if (_errorRe.hasMatch(l)) return 'ERROR';
  if (_warnRe.hasMatch(l)) return 'WARN';
  return 'INFO';
}

/// Human-readable byte size. Always uses '.' as the decimal separator, regardless of device locale —
/// the Kotlin original forces `Locale.US` for the same reason.
String humanBytes(int bytes) {
  if (bytes <= 0) return '0 B';
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var v = bytes.toDouble();
  var i = 0;
  while (v >= 1024 && i < units.length - 1) {
    v /= 1024;
    i++;
  }
  return i == 0 ? '$bytes B' : '${v.toStringAsFixed(1)} ${units[i]}';
}
