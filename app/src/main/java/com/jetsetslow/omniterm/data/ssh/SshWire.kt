package com.jetsetslow.omniterm.data.ssh

import java.io.ByteArrayOutputStream
import java.math.BigInteger
import java.security.MessageDigest
import org.bouncycastle.util.encoders.Base64

/** Reads SSH's wire encoding (RFC 4251 §5): bytes, uint32, uint64 and length-prefixed strings. */
internal class SshReader(private val data: ByteArray, private var at: Int = 0) {
    val remaining: Int get() = data.size - at

    fun byte(): Int {
        need(1)
        return data[at++].toInt() and 0xff
    }

    fun uint32(): Long {
        need(4)
        var value = 0L
        repeat(4) { value = (value shl 8) or (data[at++].toLong() and 0xff) }
        return value
    }

    /** A uint64; the largest values (OpenSSH's "forever") come back negative. */
    fun uint64(): Long {
        need(8)
        var value = 0L
        repeat(8) { value = (value shl 8) or (data[at++].toLong() and 0xff) }
        return value
    }

    fun bytes(): ByteArray {
        val length = uint32()
        if (length > remaining) throw IllegalArgumentException(TRUNCATED)
        return raw(length.toInt())
    }

    fun string(): String = String(bytes(), Charsets.UTF_8)

    fun raw(count: Int): ByteArray {
        need(count)
        return data.copyOfRange(at, at + count).also { at += count }
    }

    private fun need(count: Int) {
        if (count < 0 || count > remaining) throw IllegalArgumentException(TRUNCATED)
    }

    private companion object {
        const val TRUNCATED = "The key data ends too early."
    }
}

/** Writes SSH's wire encoding; the counterpart of [SshReader]. */
internal class SshWriter {
    private val out = ByteArrayOutputStream()

    fun byte(value: Int) = apply { out.write(value and 0xff) }

    fun uint32(value: Long) = apply { for (shift in 24 downTo 0 step 8) out.write((value shr shift).toInt() and 0xff) }

    fun bytes(value: ByteArray) = apply {
        uint32(value.size.toLong())
        out.write(value)
    }

    fun string(value: String) = bytes(value.toByteArray(Charsets.UTF_8))

    fun mpint(value: BigInteger) = bytes(value.toByteArray())

    fun raw(value: ByteArray) = apply { out.write(value) }

    fun toByteArray(): ByteArray = out.toByteArray()
}

internal object SshWire {
    fun sha256(data: ByteArray): ByteArray = MessageDigest.getInstance("SHA-256").digest(data)

    /** OpenSSH's fingerprint of a public key blob: `SHA256:` and unpadded base64. */
    fun fingerprint(blob: ByteArray): String =
        "SHA256:" + Base64.toBase64String(sha256(blob)).trimEnd('=')

    /** The algorithm name every key, certificate and signature blob starts with. */
    fun algorithm(blob: ByteArray): String = SshReader(blob).string()

    /** A public key line (`type base64 comment`) as its blob, or null when [line] is not one. */
    fun publicBlob(line: String): ByteArray? {
        val parts = line.trim().split(Regex("\\s+"))
        val blob = parts.getOrNull(1)?.let { runCatching { Base64.decode(it) }.getOrNull() } ?: return null
        return blob.takeIf { runCatching { algorithm(it) == parts[0] }.getOrDefault(false) }
    }

    fun publicLine(blob: ByteArray, comment: String): String =
        (algorithm(blob) + " " + Base64.toBase64String(blob) + " " + comment).trim()
}
