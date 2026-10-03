/// Real remote-host data models, populated from live SSH command output (see `remote_parsers.dart`).
///
/// Ported from `data/RemoteModels.kt`. These replaced the former in-memory `ServerSimulator` fakes —
/// everything here reflects the actual server.
///
/// The Kotlin originals are `data class`es with a handful of `var` fields that callers mutate in
/// place (a container's status, an image's `inUse` flag, a process's cpu/mem). Those stay mutable
/// here so the porting of call sites is mechanical; the immutable fields stay `final`.
library;

class SimContainer {
  SimContainer({
    required this.id,
    required this.name,
    required this.image,
    required this.ports,
    required this.status,
    required this.group,
    required this.host,
    this.composeWorkingDir = '',
    this.composeConfigFiles = '',
    this.composeService = '',
    this.health = 'none',
    this.restartCount = 0,
    this.createdAt = '',
    this.runtime = 'docker',
  });

  final String id;
  final String name;
  final String image;
  final String ports;

  /// "running" | "exited" | "paused" | "restarting".
  String status;

  /// docker-compose project, or "standalone".
  final String group;

  /// Owning server name.
  final String host;
  final String composeWorkingDir;
  final String composeConfigFiles;
  final String composeService;
  final String health;
  final int restartCount;
  final String createdAt;
  final String runtime;
}

class SimDockerImage {
  SimDockerImage({
    required this.id,
    required this.repository,
    required this.tag,
    required this.size,
    required this.created,
    this.inUse = false,
    this.runtime = 'docker',
  });

  final String id;
  final String repository;
  final String tag;
  final String size;
  final String created;
  bool inUse;
  final String runtime;
}

class SimDockerVolume {
  SimDockerVolume({
    required this.name,
    required this.driver,
    required this.mountpoint,
    this.inUse = false,
    this.size = '',
    this.runtime = 'docker',
  });

  final String name;
  final String driver;
  final String mountpoint;
  bool inUse;
  final String size;
  final String runtime;
}

class SimDockerNetwork {
  const SimDockerNetwork({
    required this.id,
    required this.name,
    required this.driver,
    this.subnet = '',
    this.gateway = '',
    this.containerCount = 0,
    this.runtime = 'docker',
  });

  final String id;
  final String name;
  final String driver;
  final String subnet;
  final String gateway;
  final int containerCount;
  final String runtime;
}

class KnownHost {
  const KnownHost(this.host, this.keyType, this.fingerprint);

  final String host;
  final String keyType;
  final String fingerprint;
}

class FleetLogEntry {
  const FleetLogEntry({
    required this.serverName,
    required this.serverId,
    required this.timestamp,
    required this.level,
    required this.message,
  });

  final String serverName;
  final int serverId;
  final String timestamp;
  final String level;
  final String message;
}

class SimProcess {
  SimProcess({
    required this.pid,
    required this.name,
    required this.owner,
    required this.cpu,
    required this.mem,
    required this.state,
    required this.vms,
    this.uptime = '',
  });

  final int pid;
  final String name;
  final String owner;
  double cpu;
  double mem;

  /// "R", "S", …
  String state;

  /// Human-readable virtual memory size.
  final String vms;

  /// Elapsed run time (ps etime), e.g. "01:23:45" or "2-03:04:05".
  final String uptime;
}

class SimService {
  SimService({
    required this.name,
    required this.desc,
    required this.status,
    required this.subState,
    this.enabled = false,
  });

  final String name;
  final String desc;

  /// "running" | "failed" | "dead".
  String status;

  /// "active" | "failed" | `<systemd sub>`.
  String subState;

  /// systemd `UnitFileState == "enabled"`.
  final bool enabled;
}

class SimLog {
  const SimLog({
    required this.time,
    required this.level,
    required this.source,
    required this.message,
  });

  final String time;

  /// "INFO" | "WARN" | "ERROR".
  final String level;
  final String source;
  final String message;
}

/// A remote file/directory entry (SFTP) — also carries text [content] when opened for editing.
class SftpFile {
  SftpFile({
    required this.name,
    required this.isDirectory,
    required this.size,
    required this.modDate,
    this.modTimeSeconds = 0,
    this.content = '',
  });

  final String name;
  final bool isDirectory;
  int size;
  String modDate;
  int modTimeSeconds;
  String content;
}

/// How a paste/upload name-clash was resolved by the user.
enum ConflictAction { overwrite, skip, keepBoth }

/// Whether a clashing pair is provably the same bytes, provably different, or unverifiable.
enum ConflictVerdict {
  /// Digests matched — the same bytes, so overwriting changes nothing.
  identical,

  /// Sizes or digests differ — overwriting destroys distinct content.
  different,

  /// Directory clash: contents merge rather than replace.
  directory,

  /// No hash tool on the host (or it failed). Must be treated as possibly-different.
  unknown,
}

/// One name clash between a pasted/uploaded item and an existing entry in the destination.
///
/// [verdict] is decided by comparing bytes (size first, then a digest when sizes match) — never by
/// name, size, and mtime alone, which an rsync-style copy can reproduce exactly on different
/// content.
class TransferConflict {
  const TransferConflict({
    required this.name,
    required this.verdict,
    required this.sourceSize,
    required this.destSize,
    required this.sourceMtimeSeconds,
    required this.destMtimeSeconds,
    this.action = ConflictAction.overwrite,
  });

  final String name;
  final ConflictVerdict verdict;
  final int sourceSize;
  final int destSize;
  final int sourceMtimeSeconds;
  final int destMtimeSeconds;
  final ConflictAction action;

  /// Only [action] varies once a conflict has been classified: the verdict is a measured fact about
  /// the two files, whereas the action is the user's answer to it.
  TransferConflict copyWith({ConflictAction? action}) => TransferConflict(
    name: name,
    verdict: verdict,
    sourceSize: sourceSize,
    destSize: destSize,
    sourceMtimeSeconds: sourceMtimeSeconds,
    destMtimeSeconds: destMtimeSeconds,
    action: action ?? this.action,
  );
}

/// One hit from a recursive SFTP search — [path] is the full remote path.
class SftpSearchHit {
  const SftpSearchHit({required this.path, required this.isDirectory});

  final String path;
  final bool isDirectory;
}

/// One mounted filesystem's usage. [health] is the optional SMART summary (Linux only).
class DiskUsage {
  const DiskUsage({
    required this.mount,
    required this.filesystem,
    required this.totalBytes,
    required this.usedBytes,
    this.health = '',
  });

  final String mount;
  final String filesystem;
  final int totalBytes;
  final int usedBytes;

  /// SMART health, e.g. "PASSED" / "FAILED"; "" when unknown/unavailable.
  final String health;

  double get percent => totalBytes > 0 ? usedBytes * 100.0 / totalBytes : 0.0;

  DiskUsage copyWith({String? health}) => DiskUsage(
    mount: mount,
    filesystem: filesystem,
    totalBytes: totalBytes,
    usedBytes: usedBytes,
    health: health ?? this.health,
  );
}

/// Per-block-device cumulative I/O counters (bytes), from /proc/diskstats; used to derive rates.
class DiskIo {
  const DiskIo(this.device, this.readBytes, this.writeBytes);

  final String device;
  final int readBytes;
  final int writeBytes;
}

/// One network interface: cumulative byte counters plus the per-second rates computed by the poller.
class NetInterface {
  const NetInterface(this.name, this.rxBytes, this.txBytes, {this.rxPerSec = 0, this.txPerSec = 0});

  final String name;
  final int rxBytes;
  final int txBytes;
  final int rxPerSec;
  final int txPerSec;
}

/// Point-in-time host metrics for the Monitor → Overview tab and telemetry history.
class HostMetrics {
  const HostMetrics({
    required this.cpuPercent,
    required this.memUsedBytes,
    required this.memTotalBytes,
    required this.diskUsedBytes,
    required this.diskTotalBytes,
    required this.load1,
    required this.load5,
    required this.load15,
    required this.uptimeSeconds,
    required this.procCount,
    this.perCoreCpu = const [],
    this.cpuTempC,
    this.tcpConnections = 0,
    this.disks = const [],
    this.netInterfaces = const [],
    this.diskReadPerSec = 0,
    this.diskWritePerSec = 0,
    this.os = '',
    this.platforms = const {},
    this.unavailable = const {},
  });

  final double cpuPercent;
  final int memUsedBytes;
  final int memTotalBytes;
  final int diskUsedBytes;
  final int diskTotalBytes;
  final double load1;
  final double load5;
  final double load15;
  final int uptimeSeconds;
  final int procCount;
  final List<double> perCoreCpu;
  final double? cpuTempC;
  final int tcpConnections;
  final List<DiskUsage> disks;
  final List<NetInterface> netInterfaces;

  /// Why a metric section could not be collected, keyed by section name (e.g. `DISKS`).
  ///
  /// A section the probe could not read emits `!UNAVAILABLE <reason>` instead of staying silent,
  /// because an empty disk list and a disk list that could not be read look identical on screen and
  /// mean very different things. Mirrors `HostMetrics.unavailable` on the Kotlin side.
  final Map<String, String> unavailable;

  /// Aggregate disk I/O throughput across all block devices (bytes/sec), derived by the poller from
  /// the delta between two /proc/diskstats samples. Linux only; 0 elsewhere/first poll.
  final int diskReadPerSec;
  final int diskWritePerSec;

  /// Remote OS family detected by the probe: "Linux" | "FreeBSD" | "Darwin" | "Windows" | "".
  final String os;

  /// Detected platform capabilities (e.g. "linux", "proxmox", "casaos", "homeassistant",
  /// "raspberry", "docker", "freebsd", "darwin", "windows"). Used to filter platform-specific quick
  /// scripts to relevant hosts. In-memory only (not persisted).
  final Set<String> platforms;

  double get memPercent => memTotalBytes > 0 ? memUsedBytes * 100.0 / memTotalBytes : 0.0;
  double get diskPercent => diskTotalBytes > 0 ? diskUsedBytes * 100.0 / diskTotalBytes : 0.0;

  /// Aggregate network rates across all interfaces (sum), for a headline figure.
  int get netRxPerSec => netInterfaces.fold(0, (a, i) => a + i.rxPerSec);
  int get netTxPerSec => netInterfaces.fold(0, (a, i) => a + i.txPerSec);

  /// Replaces only the fields the telemetry poller derives from two probes (`telemetry_sampling`).
  ///
  /// Deliberately not a full copyWith: everything else in a sample is a reading, and a reading is
  /// replaced by taking another one, not by editing the one you have.
  HostMetrics copyWith({
    double? cpuPercent,
    List<double>? perCoreCpu,
    List<NetInterface>? netInterfaces,
    int? diskReadPerSec,
    int? diskWritePerSec,
  }) => HostMetrics(
    cpuPercent: cpuPercent ?? this.cpuPercent,
    memUsedBytes: memUsedBytes,
    memTotalBytes: memTotalBytes,
    diskUsedBytes: diskUsedBytes,
    diskTotalBytes: diskTotalBytes,
    load1: load1,
    load5: load5,
    load15: load15,
    uptimeSeconds: uptimeSeconds,
    procCount: procCount,
    perCoreCpu: perCoreCpu ?? this.perCoreCpu,
    cpuTempC: cpuTempC,
    tcpConnections: tcpConnections,
    disks: disks,
    netInterfaces: netInterfaces ?? this.netInterfaces,
    diskReadPerSec: diskReadPerSec ?? this.diskReadPerSec,
    diskWritePerSec: diskWritePerSec ?? this.diskWritePerSec,
    os: os,
    platforms: platforms,
  );

  static const empty = HostMetrics(
    cpuPercent: 0,
    memUsedBytes: 0,
    memTotalBytes: 0,
    diskUsedBytes: 0,
    diskTotalBytes: 0,
    load1: 0,
    load5: 0,
    load15: 0,
    uptimeSeconds: 0,
    procCount: 0,
  );
}
