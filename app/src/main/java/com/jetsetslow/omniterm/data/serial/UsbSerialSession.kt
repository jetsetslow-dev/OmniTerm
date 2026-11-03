package com.jetsetslow.omniterm.data.serial

import android.hardware.usb.UsbConstants
import android.hardware.usb.UsbDevice
import android.hardware.usb.UsbDeviceConnection
import android.hardware.usb.UsbEndpoint
import android.hardware.usb.UsbInterface
import android.hardware.usb.UsbManager
import com.jetsetslow.omniterm.data.term.ByteStreamTerminalSession
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.IOException

/** A USB serial adapter plugged into the phone, and the chip OmniTerm drives it as. */
data class UsbSerialAdapter(val device: UsbDevice, val chip: UsbSerialChip) {
    /** The adapter as its maker names it, or its chip and ids when it names nothing. */
    val label: String
        get() = listOfNotNull(device.manufacturerName, device.productName).joinToString(" ").trim()
            .ifEmpty { "${chip.label} %04x:%04x".format(device.vendorId, device.productId) }

    companion object {
        /** The serial adapters plugged in now. */
        fun attached(manager: UsbManager): List<UsbSerialAdapter> =
            manager.deviceList.values.mapNotNull { device ->
                val classes = (0 until device.interfaceCount).map { device.getInterface(it).interfaceClass }
                UsbSerialChip.of(device.vendorId, device.productId, classes)?.let { UsbSerialAdapter(device, it) }
            }.sortedBy { it.device.deviceName }
    }
}

/**
 * A terminal on a USB serial adapter: a router or switch console, a single-board computer's
 * serial console, a microcontroller. The phone must have permission for the device first.
 */
class UsbSerialSession private constructor(
    private val connection: UsbDeviceConnection,
    private val claimed: List<UsbInterface>,
    private val io: AndroidUsbIo,
    private val chip: UsbSerialChip,
) : ByteStreamTerminalSession("serial-reader") {
    override val endOfStreamReason = "The adapter was unplugged"

    // A detached adapter fails every read at once instead of waiting out the timeout.
    private var instantFailures = 0

    init {
        start()
    }

    override fun readSome(buffer: ByteArray): Int {
        val started = System.nanoTime()
        val read = io.bulkRead(buffer, READ_TIMEOUT_MS)
        if (read < 0) {
            val elapsedMs = (System.nanoTime() - started) / 1_000_000
            instantFailures = if (elapsedMs < READ_TIMEOUT_MS / 4) instantFailures + 1 else 0
            return if (instantFailures >= DETACHED_AFTER_FAILURES) -1 else 0
        }
        instantFailures = 0
        return if (chip == UsbSerialChip.Ftdi) UsbSerialDrivers.stripFtdiStatus(buffer, read, io.readPacketSize) else read
    }

    override fun writeRaw(bytes: ByteArray) {
        var offset = 0
        while (offset < bytes.size) {
            val chunk = bytes.copyOfRange(offset, minOf(offset + WRITE_CHUNK, bytes.size))
            val written = io.bulkWrite(chunk, chunk.size, WRITE_TIMEOUT_MS)
            if (written <= 0) throw IOException("The adapter did not take the input")
            offset += written
        }
    }

    // A serial line has no window size to report.
    override suspend fun resize(cols: Int, rows: Int) = Unit

    override fun closeTransport() {
        claimed.forEach { runCatching { connection.releaseInterface(it) } }
        connection.close()
    }

    private class AndroidUsbIo(
        private val connection: UsbDeviceConnection,
        private val readEndpoint: UsbEndpoint,
        private val writeEndpoint: UsbEndpoint,
    ) : UsbSerialIo {
        override fun control(requestType: Int, request: Int, value: Int, index: Int, data: ByteArray?, length: Int): Int =
            connection.controlTransfer(requestType, request, value, index, data, length, CONTROL_TIMEOUT_MS)

        override fun bulkRead(buffer: ByteArray, timeoutMs: Int): Int =
            connection.bulkTransfer(readEndpoint, buffer, buffer.size, timeoutMs)

        override fun bulkWrite(buffer: ByteArray, length: Int, timeoutMs: Int): Int =
            connection.bulkTransfer(writeEndpoint, buffer, length, timeoutMs)

        override val readPacketSize: Int get() = readEndpoint.maxPacketSize
    }

    companion object {
        private const val READ_TIMEOUT_MS = 200
        private const val WRITE_TIMEOUT_MS = 2_000
        private const val CONTROL_TIMEOUT_MS = 2_000
        private const val WRITE_CHUNK = 4_096
        private const val DETACHED_AFTER_FAILURES = 20

        /** Opens [adapter] with [settings]; throws when the phone has no permission or the chip refuses. */
        suspend fun open(manager: UsbManager, adapter: UsbSerialAdapter, settings: SerialSettings): UsbSerialSession =
            withContext(Dispatchers.IO) {
                val device = adapter.device
                if (!manager.hasPermission(device)) throw IOException("OmniTerm has no permission to use this adapter")
                val connection = manager.openDevice(device) ?: throw IOException("The adapter could not be opened")
                val claimed = mutableListOf<UsbInterface>()
                try {
                    val interfaces = (0 until device.interfaceCount).map(device::getInterface)
                    // CDC-ACM splits control and data over two interfaces; the vendor chips use one.
                    val control = interfaces.firstOrNull { it.interfaceClass == UsbConstants.USB_CLASS_COMM }
                    val data = interfaces.firstOrNull { it.interfaceClass == UsbConstants.USB_CLASS_CDC_DATA && it.bulkPair() != null }
                        ?: interfaces.firstOrNull { it.bulkPair() != null }
                        ?: throw IOException("The adapter has no data endpoints")
                    for (iface in listOfNotNull(control, data).distinct()) {
                        if (!connection.claimInterface(iface, true)) throw IOException("The adapter is in use by another app")
                        claimed += iface
                    }
                    val (readEndpoint, writeEndpoint) = data.bulkPair()!!
                    val io = AndroidUsbIo(connection, readEndpoint, writeEndpoint)
                    val raw = connection.rawDescriptors ?: ByteArray(0)
                    val bcdDevice = if (raw.size >= 14) (raw[12].toInt() and 0xFF) or ((raw[13].toInt() and 0xFF) shl 8) else 0
                    val maxPacketSize0 = if (raw.size >= 8) raw[7].toInt() and 0xFF else 64
                    UsbSerialDrivers.configure(
                        adapter.chip, io, settings,
                        controlInterface = (control ?: data).id,
                        // FTDI's multi-port chips number their ports from 1.
                        port = if (adapter.chip == UsbSerialChip.Ftdi && device.interfaceCount > 1) data.id + 1 else 0,
                        bcdDevice = bcdDevice,
                        maxPacketSize0 = maxPacketSize0,
                    )
                    UsbSerialSession(connection, claimed, io, adapter.chip)
                } catch (e: Exception) {
                    claimed.forEach { runCatching { connection.releaseInterface(it) } }
                    connection.close()
                    throw e
                }
            }

        private fun UsbInterface.bulkPair(): Pair<UsbEndpoint, UsbEndpoint>? {
            val endpoints = (0 until endpointCount).map(::getEndpoint).filter { it.type == UsbConstants.USB_ENDPOINT_XFER_BULK }
            val read = endpoints.firstOrNull { it.direction == UsbConstants.USB_DIR_IN } ?: return null
            val write = endpoints.firstOrNull { it.direction == UsbConstants.USB_DIR_OUT } ?: return null
            return read to write
        }
    }
}
