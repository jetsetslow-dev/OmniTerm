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
)

data class SimDockerImage(
    val id: String,
    val repository: String,
    val tag: String,
    val size: String,
    val created: String,
    var inUse: Boolean = false
)

data class SimDockerVolume(
    val name: String,
    val driver: String,
    val mountpoint: String,
    var inUse: Boolean = false,
    val size: String = ""
)

data class SimDockerNetwork(
    val id: String,
    val name: String,
    val driver: String,
    val subnet: String = "",
    val gateway: String = "",
    val containerCount: Int = 0,
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
    var content: String = "",
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
