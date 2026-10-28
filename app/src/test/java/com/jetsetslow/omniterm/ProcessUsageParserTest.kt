package com.jetsetslow.omniterm

import com.jetsetslow.omniterm.data.DiskRate
import com.jetsetslow.omniterm.data.RemoteCommands
import com.jetsetslow.omniterm.data.RemoteParsers
import com.jetsetslow.omniterm.data.SimProcess
import com.jetsetslow.omniterm.ui.ProcessSort
import com.jetsetslow.omniterm.ui.sortProcesses
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Per-process disk and GPU use from the samples the Linux process command appends. */
class ProcessUsageParserTest {

    private val ps = """
        PID USER %CPU %MEM VSZ ELAPSED STAT COMMAND
        101 root 12.0 1.5 2048 01:00 S rsync
        202 alice 40.0 9.0 4096 02:00 R blender
        303 root 0.5 0.1 1024 03:00 S sshd
    """.trimIndent()

    // 2 s between samples: rsync read 4 MiB and wrote 2 MiB; blender's render engine was busy
    // 1.5 s through one client that sits behind two descriptors; sshd's io was unreadable.
    private val output = ps + "\n" + """
        ${RemoteCommands.PROCESS_SAMPLE_MARKER} 1000000000
        /proc/101/io:read_bytes: 1000
        /proc/101/io:write_bytes: 500
        /proc/202/io:read_bytes: 0
        /proc/202/io:write_bytes: 0
        /proc/202/fdinfo/7:drm-pdev:	0000:03:00.0
        /proc/202/fdinfo/7:drm-client-id:	42
        /proc/202/fdinfo/7:drm-engine-gfx:	1000000000 ns
        /proc/202/fdinfo/7:drm-engine-dec:	0 ns
        /proc/202/fdinfo/9:drm-pdev:	0000:03:00.0
        /proc/202/fdinfo/9:drm-client-id:	42
        /proc/202/fdinfo/9:drm-engine-gfx:	1000000000 ns
        ${RemoteCommands.PROCESS_SAMPLE_MARKER} 3000000000
        /proc/101/io:read_bytes: 4195304
        /proc/101/io:write_bytes: 2097652
        /proc/202/io:read_bytes: 0
        /proc/202/io:write_bytes: 0
        /proc/202/fdinfo/7:drm-pdev:	0000:03:00.0
        /proc/202/fdinfo/7:drm-client-id:	42
        /proc/202/fdinfo/7:drm-engine-gfx:	2500000000 ns
        /proc/202/fdinfo/7:drm-engine-dec:	0 ns
        /proc/202/fdinfo/9:drm-pdev:	0000:03:00.0
        /proc/202/fdinfo/9:drm-client-id:	42
        /proc/202/fdinfo/9:drm-engine-gfx:	2500000000 ns
    """.trimIndent()

    @Test
    fun `disk rates are the difference over the time between samples`() {
        val usage = RemoteParsers.parseProcessUsage(output)
        assertEquals(DiskRate(readBytesPerSecond = 2_097_152, writeBytesPerSecond = 1_048_576), usage.disk[101])
        assertEquals(DiskRate(0, 0), usage.disk[202])
        assertNull("Unreadable counters are unknown, not zero", usage.disk[303])
    }

    @Test
    fun `gpu use is the busiest engine with a shared client counted once`() {
        val usage = RemoteParsers.parseProcessUsage(output)
        assertTrue(usage.gpuReported)
        // 1.5 s of gfx time over 2 s; counting both descriptors would make it 150%.
        assertEquals(75f, usage.gpu.getValue(202), 0.01f)
        assertNull(usage.gpu[101])
    }

    @Test
    fun `an engine class with several engines is divided by their number`() {
        val twoEngines = output.replace(
            "/proc/202/fdinfo/7:drm-engine-gfx:\t2500000000 ns",
            "/proc/202/fdinfo/7:drm-engine-gfx:\t2500000000 ns\n/proc/202/fdinfo/7:drm-engine-capacity-gfx:\t2",
        )
        assertEquals(37.5f, RemoteParsers.parseProcessUsage(twoEngines).gpu.getValue(202), 0.01f)
    }

    @Test
    fun `intel xe cycles are a share of the gpu's total cycles`() {
        val xe = ps + "\n" + """
            ${RemoteCommands.PROCESS_SAMPLE_MARKER} 1000000000
            /proc/202/fdinfo/5:drm-pdev:	0000:00:02.0
            /proc/202/fdinfo/5:drm-client-id:	7
            /proc/202/fdinfo/5:drm-cycles-rcs:	1000
            /proc/202/fdinfo/5:drm-total-cycles-rcs:	50000
            /proc/202/fdinfo/5:drm-cycles-vcs:	0
            /proc/202/fdinfo/5:drm-total-cycles-vcs:	50000
            ${RemoteCommands.PROCESS_SAMPLE_MARKER} 2000000000
            /proc/202/fdinfo/5:drm-pdev:	0000:00:02.0
            /proc/202/fdinfo/5:drm-client-id:	7
            /proc/202/fdinfo/5:drm-cycles-rcs:	21000
            /proc/202/fdinfo/5:drm-total-cycles-rcs:	130000
            /proc/202/fdinfo/5:drm-cycles-vcs:	0
            /proc/202/fdinfo/5:drm-total-cycles-vcs:	130000
        """.trimIndent()
        val usage = RemoteParsers.parseProcessUsage(xe)
        assertTrue(usage.gpuReported)
        // 20 000 of 80 000 cycles.
        assertEquals(25f, usage.gpu.getValue(202), 0.01f)
    }

    @Test
    fun `a clock without nanoseconds counts the samples a second apart`() {
        // BusyBox date prints "%N" literally.
        val busybox = output
            .replace("${RemoteCommands.PROCESS_SAMPLE_MARKER} 1000000000", "${RemoteCommands.PROCESS_SAMPLE_MARKER} 1%N")
            .replace("${RemoteCommands.PROCESS_SAMPLE_MARKER} 3000000000", "${RemoteCommands.PROCESS_SAMPLE_MARKER} 3%N")
        assertEquals(4_194_304L, RemoteParsers.parseProcessUsage(busybox).disk.getValue(101).readBytesPerSecond)
    }

    @Test
    fun `nvidia pmon reports sm use and marks the gpu as present`() {
        val nvidia = ps + "\n" + """
            ${RemoteCommands.PROCESS_NVIDIA_MARKER}
            # gpu         pid   type     sm    mem    enc    dec    command
            # Idx           #    C/G      %      %      %      %    name
                0        202     C     64     20      -      -    blender
                0          -     -      -      -      -      -    -
        """.trimIndent()
        val usage = RemoteParsers.parseProcessUsage(nvidia)
        assertTrue(usage.gpuReported)
        assertEquals(64f, usage.gpu.getValue(202), 0.01f)
    }

    @Test
    fun `nvidia-smi without a working driver does not add a gpu column`() {
        val usage = RemoteParsers.parseProcessUsage(ps + "\n" + RemoteCommands.PROCESS_NVIDIA_MARKER + "\n")
        assertFalse(usage.gpuReported)
    }

    @Test
    fun `the process list ignores the samples after it`() {
        val nvidia = output + "\n" + RemoteCommands.PROCESS_NVIDIA_MARKER + "\n    0  202  C  64  20  -  -  blender"
        assertEquals(listOf(101, 202, 303), RemoteParsers.parseProcesses(nvidia).map { it.pid })
    }

    @Test
    fun `sorting by disk or gpu puts processes without a reading last`() {
        val procs = listOf(
            SimProcess(1, "a", "u", 1f, 1f, "S", "1K", disk = null, gpu = null),
            SimProcess(2, "b", "u", 1f, 1f, "S", "1K", disk = DiskRate(10, 0), gpu = 5f),
            SimProcess(3, "c", "u", 1f, 1f, "S", "1K", disk = DiskRate(0, 50), gpu = 0f),
        )
        assertEquals(listOf(3, 2, 1), sortProcesses(procs, ProcessSort.Disk).map { it.pid })
        assertEquals(listOf(2, 3, 1), sortProcesses(procs, ProcessSort.Gpu).map { it.pid })
    }
}
