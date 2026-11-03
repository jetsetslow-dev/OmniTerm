package com.jetsetslow.omniterm

import com.jetsetslow.omniterm.data.serial.SerialParity
import com.jetsetslow.omniterm.data.serial.SerialSettings
import com.jetsetslow.omniterm.data.serial.SerialStopBits
import com.jetsetslow.omniterm.data.serial.UsbSerialChip
import com.jetsetslow.omniterm.data.serial.UsbSerialDrivers
import com.jetsetslow.omniterm.data.serial.UsbSerialIo
import com.jetsetslow.omniterm.ui.formatSerialSettings
import com.jetsetslow.omniterm.ui.parseSerialSettings
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class UsbSerialDriversTest {
    /** Records control requests; a CH34x version read answers [version]. */
    private class RecordingIo(private val version: Int = 0x31) : UsbSerialIo {
        val requests = mutableListOf<List<Int>>()
        val payloads = mutableListOf<ByteArray?>()
        override fun control(requestType: Int, request: Int, value: Int, index: Int, data: ByteArray?, length: Int): Int {
            requests += listOf(requestType, request, value, index)
            payloads += data?.copyOf()
            if (requestType == 0xC0 && request == 0x5F) data?.set(0, version.toByte())
            return length
        }
        override fun bulkRead(buffer: ByteArray, timeoutMs: Int) = 0
        override fun bulkWrite(buffer: ByteArray, length: Int, timeoutMs: Int) = length
        override val readPacketSize = 64
    }

    @Test
    fun chipsAreKnownByTheirIdsAndCdcAdaptersByTheirInterfaces() {
        assertEquals(UsbSerialChip.Ftdi, UsbSerialChip.of(0x0403, 0x6001, listOf(0xFF)))
        assertEquals(UsbSerialChip.Cp210x, UsbSerialChip.of(0x10C4, 0xEA60, listOf(0xFF)))
        assertEquals(UsbSerialChip.Ch34x, UsbSerialChip.of(0x1A86, 0x7523, listOf(0xFF)))
        assertEquals(UsbSerialChip.Pl2303, UsbSerialChip.of(0x067B, 0x2303, listOf(0xFF)))
        assertEquals(UsbSerialChip.CdcAcm, UsbSerialChip.of(0x2E8A, 0x000A, listOf(0x02, 0x0A)))
        // A newer Prolific HXN speaks a different protocol; a keyboard is no serial adapter.
        assertNull(UsbSerialChip.of(0x067B, 0x23A3, listOf(0xFF)))
        assertNull(UsbSerialChip.of(0x046D, 0xC31C, listOf(0x03)))
    }

    @Test
    fun ftdiAndCh34xBaudDivisorsMatchTheLinuxDrivers() {
        assertEquals(0x4138 to 0, UsbSerialDrivers.ftdiBaud(9600, bcdDevice = 0x0600, port = 0))
        assertEquals(0x001A to 0, UsbSerialDrivers.ftdiBaud(115_200, bcdDevice = 0x0600, port = 0))
        assertEquals(0 to 0, UsbSerialDrivers.ftdiBaud(3_000_000, bcdDevice = 0x0600, port = 0))
        assertEquals(1 to 0, UsbSerialDrivers.ftdiBaud(2_000_000, bcdDevice = 0x0600, port = 0))
        // Multi-port chips carry the port in the index.
        assertEquals(0x001A to 1, UsbSerialDrivers.ftdiBaud(115_200, bcdDevice = 0x0700, port = 1))
        assertEquals(0xB202, UsbSerialDrivers.ch34xDivisor(9600))
        assertEquals(0xCC03, UsbSerialDrivers.ch34xDivisor(115_200))
        assertEquals(0xD901, UsbSerialDrivers.ch34xDivisor(2400))
    }

    @Test
    fun lineSettingsAreEncodedForEachChip() {
        val settings = SerialSettings(9600, 7, SerialParity.Even, SerialStopBits.Two)
        assertArrayEquals(byteArrayOf(0x80.toByte(), 0x25, 0, 0, 2, 2, 7), UsbSerialDrivers.lineCoding(settings))
        assertEquals(0xC0 or 0x02 or 0x18 or 0x04, UsbSerialDrivers.ch34xLineControl(settings))

        val cp210x = RecordingIo()
        UsbSerialDrivers.configure(UsbSerialChip.Cp210x, cp210x, settings)
        assertEquals(listOf(0x41, 0x03, (7 shl 8) or (2 shl 4) or 2, 0), cp210x.requests[2])
        assertEquals(listOf(0x41, 0x07, 0x0303, 0), cp210x.requests.last())

        val ftdi = RecordingIo()
        UsbSerialDrivers.configure(UsbSerialChip.Ftdi, ftdi, settings, bcdDevice = 0x0600)
        assertEquals(listOf(0x40, 0x03, 0x4138, 0), ftdi.requests[3])
        assertEquals(listOf(0x40, 0x04, 7 or (2 shl 8) or (2 shl 11), 0), ftdi.requests[4])
    }

    @Test
    fun oldCh34xChipsGetNoLineControlWrite() {
        val newer = RecordingIo(version = 0x31)
        UsbSerialDrivers.configure(UsbSerialChip.Ch34x, newer, SerialSettings())
        val old = RecordingIo(version = 0x27)
        UsbSerialDrivers.configure(UsbSerialChip.Ch34x, old, SerialSettings())
        assertEquals(newer.requests.size - 1, old.requests.size)
        // Baud 115200 with "send at once" bit 7, then DTR and RTS on (active low).
        assertEquals(listOf(0x40, 0x9A, 0x1312, 0xCC83), old.requests[2])
        assertEquals(listOf(0x40, 0xA4, 0xFF9F, 0), old.requests.last())
    }

    @Test
    fun ftdiStatusBytesAreRemovedFromEveryPacket() {
        // Two full packets of four, then a short one that ends the transfer.
        val buffer = byteArrayOf(1, 0x60, 'a'.code.toByte(), 'b'.code.toByte(), 1, 0x60, 'c'.code.toByte(), 'd'.code.toByte(), 1, 0x60, 'e'.code.toByte())
        val kept = UsbSerialDrivers.stripFtdiStatus(buffer, buffer.size, packetSize = 4)
        assertEquals("abcde", String(buffer, 0, kept))
        // A packet with only the status carries no data.
        assertEquals(0, UsbSerialDrivers.stripFtdiStatus(byteArrayOf(1, 0x60), 2, packetSize = 64))
    }

    @Test
    fun lastUsedSettingsRoundTrip() {
        val settings = SerialSettings(57_600, 7, SerialParity.Odd, SerialStopBits.OnePointFive)
        assertEquals(settings, parseSerialSettings(formatSerialSettings(settings)))
        assertEquals("57600 7O1.5", settings.summary)
        assertNull(parseSerialSettings("fast"))
        assertNull(parseSerialSettings("9600,9,None,One"))
    }
}
