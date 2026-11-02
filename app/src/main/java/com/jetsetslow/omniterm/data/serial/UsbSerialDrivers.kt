package com.jetsetslow.omniterm.data.serial

import java.io.IOException

/** The USB calls a serial driver makes, so drivers can be checked without an adapter. */
interface UsbSerialIo {
    /** As UsbDeviceConnection.controlTransfer: bytes transferred, or below zero on failure. */
    fun control(requestType: Int, request: Int, value: Int, index: Int, data: ByteArray? = null, length: Int = data?.size ?: 0): Int

    /** Bytes read from the adapter into [buffer], 0 when none arrived in time, below zero on failure. */
    fun bulkRead(buffer: ByteArray, timeoutMs: Int): Int

    /** Bytes written from the start of [buffer], below zero on failure. */
    fun bulkWrite(buffer: ByteArray, length: Int, timeoutMs: Int): Int

    /** The size of one packet on the read endpoint. */
    val readPacketSize: Int
}

enum class SerialParity(val code: Int) { None(0), Odd(1), Even(2), Mark(3), Space(4) }

enum class SerialStopBits(val code: Int, val label: String) { One(0, "1"), OnePointFive(1, "1.5"), Two(2, "2") }

data class SerialSettings(
    val baudRate: Int = 115_200,
    val dataBits: Int = 8,
    val parity: SerialParity = SerialParity.None,
    val stopBits: SerialStopBits = SerialStopBits.One,
) {
    /** "115200 8N1", the way serial settings are usually written. */
    val summary: String
        get() = "$baudRate $dataBits${parity.name.first()}${stopBits.label}"

    companion object {
        val BAUD_RATES = listOf(300, 1200, 2400, 4800, 9600, 19_200, 38_400, 57_600, 115_200, 230_400, 460_800, 921_600)
    }
}

/**
 * The USB-to-serial chips OmniTerm drives itself: the class-standard CDC-ACM (Arduino, Raspberry
 * Pi Pico, most new adapters) and the four vendor chips found in nearly every console cable.
 * Multi-port chips use their first port.
 */
enum class UsbSerialChip(val label: String) {
    CdcAcm("USB CDC-ACM"),
    Cp210x("Silicon Labs CP210x"),
    Ftdi("FTDI"),
    Ch34x("WCH CH34x"),
    Pl2303("Prolific PL2303");

    companion object {
        private const val CLASS_COMM = 0x02
        private const val CLASS_CDC_DATA = 0x0A

        /**
         * The chip behind an adapter, from its vendor and product ids and its interfaces' classes;
         * null for a device that is no serial adapter OmniTerm knows. Newer Prolific chips (HXN)
         * speak a different protocol and are left out rather than driven wrongly.
         */
        fun of(vendorId: Int, productId: Int, interfaceClasses: List<Int>): UsbSerialChip? = when {
            vendorId == 0x0403 -> Ftdi
            vendorId == 0x10C4 && productId in setOf(0xEA60, 0xEA61, 0xEA63, 0xEA70, 0xEA71, 0xEA7A, 0xEA7B, 0xEA80) -> Cp210x
            vendorId == 0x1A86 && productId in setOf(0x7523, 0x7522, 0x5523, 0xE523) -> Ch34x
            vendorId == 0x067B && productId == 0x2303 -> Pl2303
            CLASS_COMM in interfaceClasses && CLASS_CDC_DATA in interfaceClasses -> CdcAcm
            else -> null
        }
    }
}

/** Puts an adapter's chip into [SerialSettings] and turns DTR and RTS on, as a terminal program does. */
object UsbSerialDrivers {
    /**
     * Configures the chip. [controlInterface] is the interface its requests address (CDC-ACM's
     * communication interface, CP210x's port); [port] is an FTDI multi-port chip's port number
     * (0 on single-port chips); [bcdDevice] tells FTDI chips apart.
     */
    fun configure(chip: UsbSerialChip, io: UsbSerialIo, settings: SerialSettings, controlInterface: Int = 0, port: Int = 0, bcdDevice: Int = 0, maxPacketSize0: Int = 64) {
        require(settings.dataBits in 5..8) { "Data bits must be 5 to 8" }
        when (chip) {
            UsbSerialChip.CdcAcm -> {
                check(io.control(0x21, 0x20, 0, controlInterface, lineCoding(settings)), "set line coding")
                check(io.control(0x21, 0x22, DTR_RTS, controlInterface), "set DTR and RTS")
            }
            UsbSerialChip.Cp210x -> {
                check(io.control(0x41, 0x00, 0x0001, controlInterface), "enable the port")
                check(io.control(0x41, 0x1E, 0, controlInterface, littleEndian(settings.baudRate)), "set the baud rate")
                val lineControl = (settings.dataBits shl 8) or (settings.parity.code shl 4) or settings.stopBits.code
                check(io.control(0x41, 0x03, lineControl, controlInterface), "set data bits, parity and stop bits")
                check(io.control(0x41, 0x07, 0x0303, controlInterface), "set DTR and RTS")
            }
            UsbSerialChip.Ftdi -> {
                check(io.control(0x40, 0x00, 0, port), "reset")
                check(io.control(0x40, 0x01, 0x0303, port), "set DTR and RTS")
                check(io.control(0x40, 0x02, 0, port), "turn off flow control")
                val (value, index) = ftdiBaud(settings.baudRate, bcdDevice, port)
                check(io.control(0x40, 0x03, value, index), "set the baud rate")
                val data = settings.dataBits or (settings.parity.code shl 8) or (settings.stopBits.code shl 11)
                check(io.control(0x40, 0x04, data, port), "set data bits, parity and stop bits")
                // A short latency timer keeps typing responsive; the chip's default holds bytes 16 ms.
                io.control(0x40, 0x09, 2, port)
            }
            UsbSerialChip.Ch34x -> {
                val version = ByteArray(2)
                check(io.control(0xC0, 0x5F, 0, 0, version), "read the chip version")
                check(io.control(0x40, 0xA1, 0, 0), "start the port")
                check(io.control(0x40, 0x9A, 0x1312, ch34xDivisor(settings.baudRate) or 0x80), "set the baud rate")
                // Chips before version 0x30 have no line control register and run 8N1.
                if ((version[0].toInt() and 0xFF) >= 0x30) {
                    check(io.control(0x40, 0x9A, 0x2518, ch34xLineControl(settings)), "set data bits, parity and stop bits")
                }
                // The modem lines are active low.
                check(io.control(0x40, 0xA4, 0x60.inv() and 0xFFFF, 0), "set DTR and RTS")
            }
            UsbSerialChip.Pl2303 -> {
                val one = ByteArray(1)
                fun vendorIn(value: Int) = io.control(0xC0, 0x01, value, 0, one)
                fun vendorOut(value: Int, index: Int) = check(io.control(0x40, 0x01, value, index), "initialise the chip")
                vendorIn(0x8484); vendorOut(0x0404, 0); vendorIn(0x8484); vendorIn(0x8383)
                vendorIn(0x8484); vendorOut(0x0404, 1); vendorIn(0x8484); vendorIn(0x8383)
                vendorOut(0, 1); vendorOut(1, 0)
                // HX chips announce a 64-byte control endpoint; older ones take a different value.
                vendorOut(2, if (maxPacketSize0 == 64) 0x44 else 0x24)
                check(io.control(0x21, 0x20, 0, 0, lineCoding(settings)), "set line coding")
                check(io.control(0x21, 0x22, DTR_RTS, 0), "set DTR and RTS")
            }
        }
    }

    /**
     * Removes the two modem-status bytes an FTDI chip puts at the start of every packet it sends,
     * in place. Returns how many data bytes are left at the start of [buffer].
     */
    fun stripFtdiStatus(buffer: ByteArray, count: Int, packetSize: Int): Int {
        var kept = 0
        var packet = 0
        while (packet < count) {
            val end = minOf(packet + packetSize, count)
            val dataStart = packet + 2
            if (dataStart < end) {
                System.arraycopy(buffer, dataStart, buffer, kept, end - dataStart)
                kept += end - dataStart
            }
            packet += packetSize
        }
        return kept
    }

    /** CDC's 7-byte line coding: rate (little-endian), stop bits, parity, data bits. */
    fun lineCoding(settings: SerialSettings): ByteArray =
        littleEndian(settings.baudRate) + byteArrayOf(settings.stopBits.code.toByte(), settings.parity.code.toByte(), settings.dataBits.toByte())

    /**
     * FTDI's baud rate request: a divisor of the 48 MHz clock in eighths, as Linux's ftdi_sio
     * encodes it. Single-port FT232R and FT232BM chips take the divisor's top bit in the index;
     * the others take it in the index's high byte, with the port in its low byte.
     */
    fun ftdiBaud(baudRate: Int, bcdDevice: Int, port: Int): Pair<Int, Int> {
        require(baudRate > 0) { "Baud rate must be positive" }
        val fractions = intArrayOf(0, 3, 2, 4, 1, 5, 6, 7)
        val divisorEighths = ((48_000_000L + baudRate) / (2L * baudRate)).toInt()
        var divisor = (divisorEighths shr 3) or (fractions[divisorEighths and 7] shl 14)
        // The two fastest rates have their own codes.
        if (divisor == 1) divisor = 0 else if (divisor == 0x4001) divisor = 1
        val value = divisor and 0xFFFF
        val high = divisor ushr 16
        val index = if (bcdDevice == 0x0400 || bcdDevice == 0x0600) high else (high shl 8) or port
        return value to index
    }

    /** The CH34x prescaler and divisor for [baudRate], as Linux's ch341 driver works them out. */
    fun ch34xDivisor(baudRate: Int): Int {
        val clock = 48_000_000L
        fun clockDivider(prescaler: Int, fact: Int) = 1L shl (12 - 3 * prescaler - fact)
        val speed = baudRate.toLong().coerceIn(46, 3_000_000)
        var prescaler = 3
        while (prescaler >= 0 && speed <= clock / (clockDivider(prescaler, 1) * 512)) prescaler--
        if (prescaler < 0) throw IOException("Baud rate $baudRate is too low for this adapter")
        var fact = 1
        var divider = clockDivider(prescaler, fact)
        var div = clock / (divider * speed)
        if (div < 9 || div > 255) {
            div /= 2
            divider *= 2
            fact = 0
        }
        if (div < 2) throw IOException("Baud rate $baudRate is too high for this adapter")
        // Take the next divisor when it lands closer to the asked-for rate.
        if (16 * clock / (divider * div) - 16 * speed >= 16 * speed - 16 * clock / (divider * (div + 1))) div++
        // An even divisor on the halved clock is the same rate and tolerates more error.
        if (fact == 1 && div % 2 == 0L) {
            div /= 2
            fact = 0
        }
        return ((0x100 - div.toInt()) shl 8) or (fact shl 2) or prescaler
    }

    /** The CH34x line control register: receive and transmit on, then data bits, parity and stop bits. */
    fun ch34xLineControl(settings: SerialSettings): Int {
        val parity = when (settings.parity) {
            SerialParity.None -> 0x00
            SerialParity.Odd -> 0x08
            SerialParity.Even -> 0x18
            SerialParity.Mark -> 0x28
            SerialParity.Space -> 0x38
        }
        val stop = if (settings.stopBits == SerialStopBits.One) 0 else 0x04
        return 0xC0 or (settings.dataBits - 5) or parity or stop
    }

    private const val DTR_RTS = 0x03

    private fun littleEndian(value: Int) = byteArrayOf(value.toByte(), (value shr 8).toByte(), (value shr 16).toByte(), (value shr 24).toByte())

    private fun check(result: Int, step: String) {
        if (result < 0) throw IOException("The adapter did not accept the request to $step")
    }
}
