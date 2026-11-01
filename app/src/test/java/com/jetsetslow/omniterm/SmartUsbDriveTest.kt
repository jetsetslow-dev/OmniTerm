package com.jetsetslow.omniterm

import com.jetsetslow.omniterm.data.RemoteCommands
import com.jetsetslow.omniterm.data.SystemSpecsCommands
import com.jetsetslow.omniterm.data.SystemSpecsParser
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Before
import org.junit.Test
import java.io.File
import java.nio.file.Files
import java.util.concurrent.TimeUnit

/**
 * A Seagate Expansion drive on USB showed smartctl's errors as its drive details: "Read Device
 * Identity failed: scsi error unsupported field in scsi command" and "A mandatory SMART command
 * failed: exiting. To continue, add one or more '-T permissive' options." Its enclosure passes no
 * SMART command through, whatever the device type. SAT is tried, which most enclosures pass, then
 * the drive is named over plain SCSI and its health said to be unreadable.
 *
 * The script runs in a real POSIX shell with a stand-in `smartctl` on PATH that answers as three
 * kinds of drive do; nothing here depends on the machine having smartctl.
 */
class SmartUsbDriveTest {

    private lateinit var bin: File

    @Before
    fun setUp() {
        assumeTrue("POSIX sh is required", File("/bin/sh").canExecute())
        bin = Files.createTempDirectory("omniterm-smart").toFile()
        // usbblocked passes nothing through; usbsat needs SAT; sata answers at once. The last
        // argument is the device, and -d names the type.
        File(bin, "smartctl").apply {
            writeText(
                """
                #!/bin/sh
                for a; do dev=${'$'}a; done
                type=default; [ "${'$'}1" = -d ] && type=${'$'}2
                refuse() {
                  echo 'smartctl 7.5 2025-04-30 r5714 [x86_64-linux-7.0.0] (local build)'
                  echo 'Read Device Identity failed: scsi error unsupported field in scsi command'
                  echo 'If this is a USB connected device, look at the various --device=TYPE variants'
                  echo "A mandatory SMART command failed: exiting. To continue, add one or more '-T permissive' options."
                  exit 2
                }
                case "${'$'}dev:${'$'}type" in
                  /dev/usbblocked:scsi)
                    echo 'Vendor:               Seagate'
                    echo 'Product:              Expansion HDD'
                    echo 'User Capacity:        20,000,588,955,136 bytes [20.0 TB]'
                    echo 'Serial number:        TESTSERIAL01'
                    echo 'SMART support is:     Unavailable - device lacks SMART capability.' ;;
                  /dev/usbblocked:*) refuse ;;
                  /dev/usbsat:default)
                    echo '/dev/usbsat: Unknown USB bridge [0x152d:0x0578 (0x0209)]'
                    echo 'Please specify device type with the -d option.'
                    exit 1 ;;
                  /dev/usbsat:sat|/dev/sata:default)
                    echo 'Device Model:     WDC WD40EFRX-68N32N0'
                    echo 'SMART overall-health self-assessment test result: PASSED' ;;
                  *) refuse ;;
                esac
                """.trimIndent() + "\n",
            )
            setExecutable(true)
        }
    }

    @After
    fun tearDown() {
        if (::bin.isInitialized) bin.deleteRecursively()
    }

    private fun smartOutput(): String {
        val script = RemoteCommands.OT_HELPER + SystemSpecsCommands.smart("usbblocked usbsat sata")
        val proc = ProcessBuilder("/bin/sh", "-c", script)
            .redirectErrorStream(true)
            .apply { environment()["PATH"] = bin.absolutePath + ":" + System.getenv("PATH") }
            .start()
        val output = proc.inputStream.bufferedReader().readText()
        check(proc.waitFor(30, TimeUnit.SECONDS)) { "script did not finish" }
        return output.substringAfter("@SMART\n")
    }

    @Test
    fun `a drive whose enclosure passes nothing through is named and says why its health is missing`() {
        val blocked = SystemSpecsParser.smartctl(smartOutput()).getValue("usbblocked")
        val labels = blocked.map { it.label }
        assertEquals("Unavailable", blocked.first { it.label == "SMART health" }.value)
        assertTrue(blocked.first { it.label == "SMART" }.value.contains("USB enclosure does not pass SMART data through"))
        assertEquals("Expansion HDD", blocked.first { it.label == "Product" }.value)
        assertFalse("smartctl's errors are not drive details", labels.any { "failed" in it || "mandatory" in it })
    }

    @Test
    fun `a drive that needs SAT is read as SAT, and one that does not is read as it is`() {
        val smart = SystemSpecsParser.smartctl(smartOutput())
        assertEquals("PASSED", smart.getValue("usbsat").first { it.label == "SMART health" }.value)
        assertEquals("PASSED", smart.getValue("sata").first { it.label == "SMART health" }.value)
        assertTrue(smart.values.flatten().none { it.value.contains("USB bridge") })
    }

    @Test
    fun `smartctl's errors alone leave no made-up fields`() {
        val raw = SystemSpecsCommands.DEVICE_MARKER + "sdz\n" +
            "Read Device Identity failed: scsi error unsupported field in scsi command\n" +
            "A mandatory SMART command failed: exiting. To continue, add one or more '-T permissive' options.\n"
        assertTrue(SystemSpecsParser.smartctl(raw).isEmpty())
    }
}
