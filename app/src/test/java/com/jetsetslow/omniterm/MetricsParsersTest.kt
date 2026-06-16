package com.jetsetslow.omniterm

import com.jetsetslow.omniterm.data.RemoteCommands
import com.jetsetslow.omniterm.data.RemoteParsers
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class MetricsParsersTest {

    @Test
    fun normaliseOsMapsFamilies() {
        assertEquals("Linux", RemoteCommands.normaliseOs("Linux\n"))
        assertEquals("FreeBSD", RemoteCommands.normaliseOs("FreeBSD"))
        assertEquals("Darwin", RemoteCommands.normaliseOs("Darwin"))
        assertEquals("Windows", RemoteCommands.normaliseOs("Windows"))
        assertEquals("Windows", RemoteCommands.normaliseOs("'uname' is not recognized as an internal or external command"))
        assertEquals("Linux", RemoteCommands.normaliseOs("SunOS")) // unknown unix -> Linux superset
    }

    @Test
    fun parseProcessesReadsEtimeAndSkipsHeader() {
        val out = """
            PID USER %CPU %MEM VSZ ELAPSED STAT COMMAND
            101 root 12.5 3.2 204800 01:23:45 R nginx
            202 www 1.0 0.5 102400 2-03:04:05 S php-fpm
        """.trimIndent()
        val procs = RemoteParsers.parseProcesses(out)
        assertEquals(2, procs.size)
        assertEquals(101, procs[0].pid)
        assertEquals("01:23:45", procs[0].uptime)
        assertEquals("nginx", procs[0].name)
        assertEquals("R", procs[0].state)
        assertEquals("2-03:04:05", procs[1].uptime)
    }

    @Test
    fun parseDiskIoSumsWholeDisksOnly() {
        val ds = """
            8 0 sda 1000 0 2000 0 500 0 4000 0 0 0 0
            8 1 sda1 100 0 200 0 50 0 400 0 0 0 0
            259 0 nvme0n1 10 0 80 0 5 0 16 0 0 0 0
        """.trimIndent()
        val io = RemoteParsers.parseDiskIo(ds)
        assertTrue("sda" in io && "nvme0n1" in io)
        assertTrue("sda1" !in io) // partitions excluded
        assertEquals(2000L * 512, io["sda"]!!.readBytes)
        assertEquals(4000L * 512, io["sda"]!!.writeBytes)
    }

    @Test
    fun parseMetricsWindowsPopulatesCpuMemDisk() {
        val out = "@OS\nWindows\n@WINCPU\n23\n@WINMEM\n8589934592 4294967296\n@WINDISK\nC: 107374182400 53687091200\n@WINUP\n3600\n@WINPROC\n140"
        val m = RemoteParsers.parseMetrics(out)
        assertEquals("Windows", m.os)
        assertEquals(23, m.cpuPercent.toInt())
        assertEquals(8589934592L, m.memTotalBytes)
        assertEquals(4294967296L, m.memUsedBytes)
        assertEquals(1, m.disks.size)
        assertEquals(3600L, m.uptimeSeconds)
        assertEquals(140, m.procCount)
    }

    @Test
    fun parseDisksFiltersPseudoFilesystemsAndKeepsRealMounts() {
        val df = """
            /dev/sda1 100000000000 40000000000 60000000000 40% /
            tmpfs 8000000000 0 8000000000 0% /dev/shm
            /dev/sdb1 500000000000 100000000000 400000000000 20% /data
            overlay 100000000000 50000000000 50000000000 50% /var/lib/docker/overlay2/x
        """.trimIndent()
        val disks = RemoteParsers.parseDisks(df)
        // Root and /data kept; tmpfs (pseudo) and the overlay under /var... kept? overlay fs is pseudo -> dropped.
        val mounts = disks.map { it.mount }.toSet()
        assertTrue("/" in mounts)
        assertTrue("/data" in mounts)
        assertTrue("/dev/shm" !in mounts) // pseudo + under /dev
        assertTrue(disks.none { it.filesystem == "overlay" })
        val root = disks.first { it.mount == "/" }
        assertEquals(100000000000L, root.totalBytes)
        assertEquals(40, root.percent.toInt())
    }

    @Test
    fun parseProcStatExtractsIdleAndTotalPerCore() {
        val stat = """
            cpu  100 0 100 700 100 0 0 0 0 0
            cpu0 50 0 50 350 50 0 0 0 0 0
            cpu1 50 0 50 350 50 0 0 0 0 0
        """.trimIndent()
        val m = RemoteParsers.parseProcStat(stat)
        assertTrue("cpu" in m && "cpu0" in m && "cpu1" in m)
        // idle = idle(700) + iowait(100) = 800; total = sum of all = 1000.
        assertEquals(800L, m["cpu"]!!.first)
        assertEquals(1000L, m["cpu"]!!.second)
    }

    @Test
    fun parseNetDevSkipsLoopbackAndReadsRxTx() {
        val dev = """
            Inter-|   Receive                                                |  Transmit
             face |bytes    packets errs drop fifo frame compressed multicast|bytes    packets
                lo:  1000      10    0    0    0     0          0         0    1000      10
              eth0: 5000000   5000  0    0    0     0          0         0   2000000    3000
        """.trimIndent()
        val m = RemoteParsers.parseNetDev(dev)
        assertTrue("lo" !in m)
        assertEquals(5000000L, m["eth0"]!!.first)
        assertEquals(2000000L, m["eth0"]!!.second)
    }
}
