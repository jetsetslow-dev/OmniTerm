package com.jetsetslow.omniterm.data

/**
 * Real remote-host data models, populated from live SSH command output (see [RemoteParsers]).
 * These replaced the former in-memory `ServerSimulator` fakes — everything here reflects the
 * actual server.
 */

data class SimContainer(
    val id: String,
    val name: String,
    val image: String,
    val ports: String,
    var status: String,   // "running" | "exited"
    val group: String,    // docker-compose project, or "standalone"
    val host: String,     // owning server name
    val composeWorkingDir: String = "",
    val composeConfigFiles: String = "",
    val composeService: String = "",
    val health: String = "none",
    val restartCount: Int = 0,
    val createdAt: String = "",
    val runtime: String = "docker",
)

data class SimDockerImage(
    val id: String,
    val repository: String,
    val tag: String,
    val size: String,
    val created: String,
    var inUse: Boolean = false,
    val runtime: String = "docker",
)

data class SimDockerVolume(
    val name: String,
    val driver: String,
    val mountpoint: String,
    var inUse: Boolean = false,
    val size: String = "",
    val runtime: String = "docker",
)

data class SimDockerNetwork(
    val id: String,
    val name: String,
    val driver: String,
    val subnet: String = "",
    val gateway: String = "",
    val containerCount: Int = 0,
    val runtime: String = "docker",
)

data class KnownHost(val host: String, val keyType: String, val fingerprint: String)

data class FleetLogEntry(
    val serverName: String,
    val serverId: Int,
    val timestamp: String,
    val level: String,
    val message: String,
)

data class SimProcess(
    val pid: Int,
    val name: String,
    val owner: String,
    var cpu: Float,
    var mem: Float,
    var state: String,    // "R", "S", ...
    val vms: String,      // human-readable virtual memory size
    val uptime: String = "",  // elapsed run time (ps etime), e.g. "01:23:45" or "2-03:04:05"
    /** Disk throughput over the sampled second; null when its counters could not be read. */
    val disk: DiskRate? = null,
    /** Busiest GPU engine's use over the sampled second, 0–100; null when not reported. */
    val gpu: Float? = null,
)

data class DiskRate(val readBytesPerSecond: Long, val writeBytesPerSecond: Long) {
    val totalBytesPerSecond: Long get() = readBytesPerSecond + writeBytesPerSecond
}

/** A tmux session running on a host, as [RemoteParsers.parseTmuxSessions] read it. */
data class RemoteTmuxSession(
    val name: String,
    val windows: Int,
    /** How many tmux clients are attached to it right now, anywhere. */
    val attachedClients: Int,
    val createdAtMs: Long,
)

/** What [RemoteParsers.parseProcessUsage] found: per-pid disk and GPU use. */
data class ProcessUsage(
    val disk: Map<Int, DiskRate>,
    val gpu: Map<Int, Float>,
    /** True when the host reported a GPU use source, even if every process was idle on it. */
    val gpuReported: Boolean,
    /** A tool the host lacks that would report more, such as nvidia-smi for an NVIDIA card. */
    val missingTool: HostTool? = null,
)

data class SimService(
    val name: String,
    val desc: String,
    var status: String,   // "running" | "failed" | "dead"
    var subState: String, // "active" | "failed" | <systemd sub>
    val enabled: Boolean = false, // systemd UnitFileState == "enabled"
)

data class SimLog(
    val time: String,
    val level: String,    // "INFO" | "WARN" | "ERROR"
    val source: String,
    val message: String,
)

/** A remote file/directory entry (SFTP) — also carries text [content] when opened for editing. */
data class SftpFile(
    val name: String,
    val isDirectory: Boolean,
    var size: Long,
    var modDate: String,
    var modTimeSeconds: Long = 0L,
    var content: String = "",
)

/** How a paste/upload name-clash was resolved by the user. */
enum class ConflictAction { OVERWRITE, SKIP, KEEP_BOTH }

/** Whether a clashing pair is provably the same bytes, provably different, or unverifiable. */
enum class ConflictVerdict {
    /** Digests matched — the same bytes, so overwriting changes nothing. */
    IDENTICAL,
    /** Sizes or digests differ — overwriting destroys distinct content. */
    DIFFERENT,
    /** Directory clash: contents merge rather than replace. */
    DIRECTORY,
    /** No hash tool on the host (or it failed). Must be treated as possibly-different. */
    UNKNOWN,
}

/**
 * One name clash between a pasted/uploaded item and an existing entry in the destination.
 *
 * [verdict] is decided by comparing bytes (size first, then a digest when sizes match) — never by
 * name, size, and mtime alone, which an rsync-style copy can reproduce exactly on different content.
 */
data class TransferConflict(
    val name: String,
    val verdict: ConflictVerdict,
    val sourceSize: Long,
    val destSize: Long,
    val sourceMtimeSeconds: Long,
    val destMtimeSeconds: Long,
    val action: ConflictAction = ConflictAction.OVERWRITE,
)

/** One hit from a recursive SFTP search — [path] is the full remote path. */
data class SftpSearchHit(
    val path: String,
    val isDirectory: Boolean,
)

/** One mounted filesystem's usage. [health] is the optional SMART summary (Linux only). */
data class DiskUsage(
    val mount: String,
    val filesystem: String,
    val totalBytes: Long,
    val usedBytes: Long,
    val health: String = "",   // SMART health, e.g. "PASSED" / "FAILED"; "" when unknown/unavailable
) {
    val percent: Float get() = if (totalBytes > 0) usedBytes * 100f / totalBytes else 0f
}

/** Per-block-device cumulative I/O counters (bytes), from /proc/diskstats; used to derive rates. */
data class DiskIo(
    val device: String,
    val readBytes: Long,
    val writeBytes: Long,
)

/** One network interface: cumulative byte counters plus the per-second rates computed by the poller. */
data class NetInterface(
    val name: String,
    val rxBytes: Long,
    val txBytes: Long,
    val rxPerSec: Long = 0,
    val txPerSec: Long = 0,
)

/** Point-in-time host metrics for the Monitor → Overview tab and telemetry history. */
data class HostMetrics(
    val cpuPercent: Float,
    val memUsedBytes: Long,
    val memTotalBytes: Long,
    val diskUsedBytes: Long,
    val diskTotalBytes: Long,
    val load1: Float,
    val load5: Float,
    val load15: Float,
    val uptimeSeconds: Long,
    val procCount: Int,
    val perCoreCpu: List<Float> = emptyList(),
    val cpuTempC: Float? = null,
    val tcpConnections: Int = 0,
    val disks: List<DiskUsage> = emptyList(),
    val netInterfaces: List<NetInterface> = emptyList(),
    // Aggregate disk I/O throughput across all block devices (bytes/sec), derived by the poller
    // from the delta between two /proc/diskstats samples. Linux only; 0 elsewhere/first poll.
    val diskReadPerSec: Long = 0,
    val diskWritePerSec: Long = 0,
    /**
     * Why a metric section could not be collected, keyed by section name (e.g. "DISKS").
     *
     * A section the probe could not read emits `!UNAVAILABLE <reason>` rather than staying silent,
     * because an empty disk list and a disk list that could not be read look identical on screen
     * and mean very different things. Surfacing the reason turns "this host has no partitions" into
     * "df was blocked by an unreachable network mount", which is actionable.
     */
    val unavailable: Map<String, String> = emptyMap(),
    // Remote OS family detected by the probe: "Linux" | "FreeBSD" | "Darwin" | "Windows" | "".
    val os: String = "",
    // Detected platform capabilities (e.g. "linux", "proxmox", "casaos", "homeassistant",
    // "raspberry", "docker", "freebsd", "darwin", "windows"). Used to filter platform-specific
    // quick scripts to relevant hosts. In-memory only (not persisted).
    val platforms: Set<String> = emptySet(),
) {
    val memPercent: Float get() = if (memTotalBytes > 0) memUsedBytes * 100f / memTotalBytes else 0f
    val diskPercent: Float get() = if (diskTotalBytes > 0) diskUsedBytes * 100f / diskTotalBytes else 0f

    /** Aggregate network rates across all interfaces (sum), for a headline figure. */
    val netRxPerSec: Long get() = netInterfaces.sumOf { it.rxPerSec }
    val netTxPerSec: Long get() = netInterfaces.sumOf { it.txPerSec }

    companion object {
        val EMPTY = HostMetrics(0f, 0, 0, 0, 0, 0f, 0f, 0f, 0, 0)
    }
}
