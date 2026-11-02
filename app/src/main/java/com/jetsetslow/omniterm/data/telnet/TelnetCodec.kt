package com.jetsetslow.omniterm.data.telnet

import java.io.ByteArrayOutputStream

/**
 * Telnet's in-band commands (RFC 854) and the options a terminal needs: binary (RFC 856), echo
 * (RFC 857), suppress go-ahead (RFC 858), terminal type (RFC 1091) and window size (RFC 1073).
 * Every other option is refused.
 *
 * Decoding strips commands from the host's bytes and collects the replies to send back. Encoding
 * escapes the command byte in typed input and ends a typed CR the way the protocol needs. Until
 * the host says it will echo, typed input is echoed here, as the usual Telnet client does.
 */
class TelnetCodec(cols: Int, rows: Int, private val terminalType: String = "XTERM-256COLOR") {
    private enum class State { Data, Command, Option, Sub, SubCommand, AfterCr }

    private var state = State.Data
    private var verb = 0
    private val sub = ByteArrayOutputStream()

    // Options this side has agreed to perform (WILL), and those the host performs (its WILL).
    private val localEnabled = mutableSetOf<Int>()
    private val remoteEnabled = mutableSetOf<Int>()
    // Asked for at the start, so the host's agreement needs no reply.
    private val localAsked = mutableSetOf<Int>()
    private val remoteAsked = mutableSetOf<Int>()

    private var cols = cols.coerceIn(1, 0xFFFF)
    private var rows = rows.coerceIn(1, 0xFFFF)

    /** True once the host echoes what is typed, so it is no longer echoed here. */
    @get:Synchronized val hostEchoes: Boolean get() = ECHO in remoteEnabled

    /**
     * What to offer when connecting to a Telnet server (port 23): window size, terminal type and
     * character-at-a-time input. Services on other ports often speak no Telnet at all, so nothing
     * is offered to them unless they ask.
     */
    @Synchronized
    fun opening(): ByteArray {
        localAsked += listOf(NAWS, TTYPE)
        remoteAsked += SGA
        return byteArrayOf(IAC, WILL, NAWS.toByte(), IAC, WILL, TTYPE.toByte(), IAC, DO, SGA.toByte())
    }

    /** The terminal bytes in [input]'s first [count] bytes; replies for the host go to [replies]. */
    @Synchronized
    fun decode(input: ByteArray, count: Int, replies: ByteArrayOutputStream): ByteArray {
        val out = ByteArrayOutputStream(count)
        for (i in 0 until count) {
            val b = input[i].toInt() and 0xFF
            when (state) {
                State.Data, State.AfterCr -> {
                    val afterCr = state == State.AfterCr
                    state = State.Data
                    when {
                        b == IAC_INT -> state = State.Command
                        // A bare CR is sent as CR NUL; the NUL is not data.
                        afterCr && b == 0 && BINARY !in remoteEnabled -> Unit
                        else -> {
                            out.write(b)
                            if (b == CR) state = State.AfterCr
                        }
                    }
                }
                State.Command -> when (b) {
                    IAC_INT -> { out.write(IAC_INT); state = State.Data }
                    WILL_INT, WONT_INT, DO_INT, DONT_INT -> { verb = b; state = State.Option }
                    SB_INT -> { sub.reset(); state = State.Sub }
                    // NOP, data mark, break, go ahead and the rest carry nothing for a terminal.
                    else -> state = State.Data
                }
                State.Option -> {
                    negotiate(verb, b, replies)
                    state = State.Data
                }
                State.Sub -> if (b == IAC_INT) state = State.SubCommand else sub.write(b)
                State.SubCommand -> when (b) {
                    SE_INT -> { subnegotiation(sub.toByteArray(), replies); state = State.Data }
                    IAC_INT -> { sub.write(IAC_INT); state = State.Sub }
                    else -> state = State.Data
                }
            }
        }
        return out.toByteArray()
    }

    /** Typed [bytes] as sent: the command byte doubled, and CR followed by NUL outside binary mode. */
    @Synchronized
    fun encode(bytes: ByteArray): ByteArray {
        val out = ByteArrayOutputStream(bytes.size + 4)
        bytes.forEachIndexed { i, byte ->
            val b = byte.toInt() and 0xFF
            out.write(b)
            when {
                b == IAC_INT -> out.write(IAC_INT)
                b == CR && BINARY !in localEnabled && bytes.getOrNull(i + 1)?.toInt() != LF -> out.write(0)
            }
        }
        return out.toByteArray()
    }

    /** What to show for [typed] while the host does not echo: Enter as a new line, erase as erase. */
    @Synchronized
    fun localEcho(typed: ByteArray): ByteArray? {
        if (ECHO in remoteEnabled) return null
        val out = ByteArrayOutputStream(typed.size + 2)
        for (byte in typed) {
            when (val b = byte.toInt() and 0xFF) {
                CR -> { out.write(CR); out.write(LF) }
                LF -> Unit
                0x7F, 0x08 -> out.write(byteArrayOf(0x08, 0x20, 0x08))
                // Escape sequences (arrow keys) would move the cursor here, not on the host.
                0x1B -> return out.toByteArray()
                else -> out.write(b)
            }
        }
        return out.toByteArray()
    }

    /** The window size report for the new size, or null when the host never asked for one. */
    @Synchronized
    fun resize(cols: Int, rows: Int): ByteArray? {
        this.cols = cols.coerceIn(1, 0xFFFF)
        this.rows = rows.coerceIn(1, 0xFFFF)
        return if (NAWS in localEnabled) windowSize() else null
    }

    private fun negotiate(verb: Int, option: Int, replies: ByteArrayOutputStream) {
        when (verb) {
            DO_INT -> if (option in LOCAL_OPTIONS) {
                val asked = localAsked.remove(option)
                if (localEnabled.add(option)) {
                    if (!asked) replies.write(byteArrayOf(IAC, WILL, option.toByte()))
                    if (option == NAWS) replies.write(windowSize())
                }
            } else {
                replies.write(byteArrayOf(IAC, WONT, option.toByte()))
            }
            DONT_INT -> {
                localAsked.remove(option)
                if (localEnabled.remove(option)) replies.write(byteArrayOf(IAC, WONT, option.toByte()))
            }
            WILL_INT -> if (option in REMOTE_OPTIONS) {
                val asked = remoteAsked.remove(option)
                if (remoteEnabled.add(option) && !asked) replies.write(byteArrayOf(IAC, DO, option.toByte()))
            } else {
                replies.write(byteArrayOf(IAC, DONT, option.toByte()))
            }
            WONT_INT -> {
                remoteAsked.remove(option)
                if (remoteEnabled.remove(option)) replies.write(byteArrayOf(IAC, DONT, option.toByte()))
            }
        }
    }

    private fun subnegotiation(body: ByteArray, replies: ByteArrayOutputStream) {
        // TTYPE SEND: answer with the terminal type.
        if (body.size >= 2 && body[0].toInt() == TTYPE && body[1].toInt() == 1 && TTYPE in localEnabled) {
            replies.write(byteArrayOf(IAC, SB, TTYPE.toByte(), 0))
            replies.write(terminalType.toByteArray(Charsets.US_ASCII))
            replies.write(byteArrayOf(IAC, SE))
        }
    }

    private fun windowSize(): ByteArray {
        val out = ByteArrayOutputStream(9)
        out.write(byteArrayOf(IAC, SB, NAWS.toByte()))
        // Each 16-bit value is sent high byte first, and a 255 in it is doubled like any data.
        for (value in intArrayOf(cols, rows)) {
            for (b in intArrayOf(value shr 8 and 0xFF, value and 0xFF)) {
                out.write(b)
                if (b == IAC_INT) out.write(b)
            }
        }
        out.write(byteArrayOf(IAC, SE))
        return out.toByteArray()
    }

    companion object {
        private const val IAC_INT = 255
        private const val DONT_INT = 254
        private const val DO_INT = 253
        private const val WONT_INT = 252
        private const val WILL_INT = 251
        private const val SB_INT = 250
        private const val SE_INT = 240

        const val IAC = IAC_INT.toByte()
        const val DONT = DONT_INT.toByte()
        const val DO = DO_INT.toByte()
        const val WONT = WONT_INT.toByte()
        const val WILL = WILL_INT.toByte()
        const val SB = SB_INT.toByte()
        const val SE = SE_INT.toByte()

        const val BINARY = 0
        const val ECHO = 1
        const val SGA = 3
        const val TTYPE = 24
        const val NAWS = 31

        private const val CR = 0x0D
        private const val LF = 0x0A

        private val LOCAL_OPTIONS = setOf(BINARY, SGA, TTYPE, NAWS)
        private val REMOTE_OPTIONS = setOf(BINARY, ECHO, SGA)
    }
}
