package com.jetsetslow.omniterm.data.term

/** Strict incremental UTF-8 decoder for arbitrary transport read boundaries. */
class Utf8StreamDecoder {
    private var pending = ByteArray(0)

    fun reset() { pending = ByteArray(0) }

    fun decode(bytes: ByteArray, endOfInput: Boolean = false): String {
        val buf = if (pending.isEmpty()) bytes else pending + bytes
        val out = StringBuilder(buf.size)
        var i = 0
        while (i < buf.size) {
            val b0 = buf[i].toInt() and 0xFF
            val len = when {
                b0 < 0x80 -> 1
                b0 in 0xC2..0xDF -> 2
                b0 in 0xE0..0xEF -> 3
                b0 in 0xF0..0xF4 -> 4
                else -> 1
            }
            if (len == 1) {
                out.append(if (b0 < 0x80) b0.toChar() else REPLACEMENT)
                i++
                continue
            }
            // An incomplete prefix is pending only while every byte received so far is a valid
            // continuation. If an ASCII/new lead byte already disproves the sequence, emit U+FFFD
            // now and reprocess that byte instead of hiding valid terminal output indefinitely.
            val availableContinuations = minOf(len - 1, buf.size - i - 1)
            var malformedPrefix = false
            for (k in 1..availableContinuations) {
                if ((buf[i + k].toInt() and 0xC0) != 0x80) {
                    malformedPrefix = true
                    break
                }
            }
            if (malformedPrefix) {
                out.append(REPLACEMENT)
                i++
                continue
            }
            if (i + len > buf.size && !endOfInput) break
            if (i + len > buf.size) {
                out.append(REPLACEMENT)
                i = buf.size
                continue
            }
            var cp = when (len) { 2 -> b0 and 0x1F; 3 -> b0 and 0x0F; else -> b0 and 0x07 }
            var valid = true
            for (k in 1 until len) {
                val next = buf[i + k].toInt() and 0xFF
                if (next and 0xC0 != 0x80) { valid = false; break }
                cp = (cp shl 6) or (next and 0x3F)
            }
            val min = when (len) { 2 -> 0x80; 3 -> 0x800; else -> 0x10000 }
            if (!valid || cp < min || cp in 0xD800..0xDFFF || cp > 0x10FFFF) {
                out.append(REPLACEMENT)
                i++ // preserve any valid byte that followed the malformed lead
            } else {
                if (cp <= 0xFFFF) out.append(cp.toChar())
                else {
                    val v = cp - 0x10000
                    out.append((0xD800 + (v shr 10)).toChar())
                    out.append((0xDC00 + (v and 0x3FF)).toChar())
                }
                i += len
            }
        }
        pending = if (i < buf.size) buf.copyOfRange(i, buf.size) else ByteArray(0)
        return out.toString()
    }

    fun finish(): String = decode(ByteArray(0), endOfInput = true)

    private companion object { const val REPLACEMENT = '\uFFFD' }
}
