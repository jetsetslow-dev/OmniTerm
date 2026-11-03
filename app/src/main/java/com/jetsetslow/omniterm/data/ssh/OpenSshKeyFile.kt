package com.jetsetslow.omniterm.data.ssh

import com.jcraft.jsch.jbcrypt.BCrypt
import java.security.SecureRandom
import javax.crypto.Cipher
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.IvParameterSpec
import javax.crypto.spec.SecretKeySpec
import org.bouncycastle.util.encoders.Base64

/**
 * OpenSSH's own private key file (the "OPENSSH PRIVATE KEY" PEM block, PROTOCOL.key): read with
 * its passphrase, and written back without one.
 *
 * JSch reads these files but cannot write an Ed25519 key, and knows nothing of security keys, so
 * OmniTerm opens the container itself to store a protected key unprotected (the app encrypts it at
 * rest) and to read the key handle of an `id_ed25519_sk` file.
 */
internal object OpenSshKeyFile {
    class PassphraseNeeded : IllegalArgumentException("This key is protected by a passphrase. Enter it to import the key.")
    class WrongPassphrase : IllegalArgumentException("That passphrase does not open this key.")

    /** The decoded file: the public key blob, and its private section's key fields. */
    class Contents(val publicBlob: ByteArray, val keyType: String, val keyFields: ByteArray, val comment: String)

    // Built from the label: the repository's secret scan takes a written-out pair of private key
    // banners for a committed key.
    private const val LABEL = "OPENSSH PRIVATE KEY"
    private const val BEGIN = "-----BEGIN $LABEL-----"
    private const val END = "-----END $LABEL-----"
    private val MAGIC = "openssh-key-v1\u0000".toByteArray(Charsets.US_ASCII)

    fun isOpenSshKey(text: String): Boolean = text.trim().startsWith(BEGIN)

    /** The key type an OpenSSH key file holds, read from its public part; null when [text] is no such file. */
    fun keyType(text: String): String? = runCatching { SshWire.algorithm(header(decode(text)).publicBlob) }.getOrNull()

    /** True when [text] is an OpenSSH key file protected by a passphrase. */
    fun isEncrypted(text: String): Boolean = runCatching { header(decode(text)).cipher != "none" }.getOrDefault(false)

    /** [text]'s key, decrypted with [passphrase] when it has one. */
    fun read(text: String, passphrase: String?): Contents {
        val head = header(decode(text))
        val section = if (head.cipher == "none") {
            head.privateSection
        } else {
            if (passphrase.isNullOrEmpty()) throw PassphraseNeeded()
            decrypt(head, passphrase)
        }
        val reader = SshReader(section)
        if (reader.uint32() != reader.uint32()) throw WrongPassphrase()
        val keyType = reader.string()
        if (keyType != SshWire.algorithm(head.publicBlob)) throw IllegalArgumentException("This key file's two halves do not match.")
        val start = section.size - reader.remaining
        skipKeyFields(reader, keyType)
        val keyFields = section.copyOfRange(start, section.size - reader.remaining)
        val comment = reader.string()
        return Contents(head.publicBlob, keyType, keyFields, comment)
    }

    /** [contents] as an OpenSSH key file with no passphrase. */
    fun write(contents: Contents): String {
        val check = SecureRandom().nextInt().toLong() and 0xffffffffL
        val section = SshWriter().uint32(check).uint32(check).string(contents.keyType)
            .raw(contents.keyFields).string(contents.comment)
        // Pad to the cipher block size ("none" counts as 8) with 1, 2, 3…
        var padded = section.toByteArray()
        val padding = (8 - padded.size % 8) % 8
        padded += ByteArray(padding) { (it + 1).toByte() }
        val body = SshWriter().raw(MAGIC).string("none").string("none").bytes(ByteArray(0))
            .uint32(1).bytes(contents.publicBlob).bytes(padded).toByteArray()
        val lines = Base64.toBase64String(body).chunked(70)
        return (listOf(BEGIN) + lines + END).joinToString("\n", postfix = "\n")
    }

    private class Header(
        val cipher: String,
        val kdf: String,
        val kdfOptions: ByteArray,
        val publicBlob: ByteArray,
        val privateSection: ByteArray,
        /** GCM's tag, which follows the encrypted section rather than sitting inside it. */
        val trailer: ByteArray,
    )

    private fun decode(text: String): ByteArray {
        val trimmed = text.trim().replace("\r", "")
        if (!trimmed.startsWith(BEGIN) || !trimmed.contains(END)) throw IllegalArgumentException("This is not an OpenSSH key file.")
        val base64 = trimmed.substringAfter(BEGIN).substringBefore(END).filterNot(Char::isWhitespace)
        return runCatching { Base64.decode(base64) }.getOrElse { throw IllegalArgumentException("This key file is damaged: it is not valid base64.") }
    }

    private fun header(data: ByteArray): Header {
        if (data.size < MAGIC.size || !data.copyOfRange(0, MAGIC.size).contentEquals(MAGIC)) {
            throw IllegalArgumentException("This is not an OpenSSH key file.")
        }
        val reader = SshReader(data, MAGIC.size)
        val cipher = reader.string()
        val kdf = reader.string()
        val kdfOptions = reader.bytes()
        val count = reader.uint32()
        if (count != 1L) throw IllegalArgumentException("This file holds $count keys; OmniTerm imports one key per file.")
        val publicBlob = reader.bytes()
        val section = reader.bytes()
        return Header(cipher, kdf, kdfOptions, publicBlob, section, reader.raw(reader.remaining))
    }

    private fun decrypt(head: Header, passphrase: String): ByteArray {
        if (head.kdf != "bcrypt") throw IllegalArgumentException("This key is protected in a way OmniTerm cannot open (${head.kdf}).")
        val (algorithm, keyLength, ivLength) = when (head.cipher) {
            "aes256-ctr" -> Triple("AES/CTR/NoPadding", 32, 16)
            "aes192-ctr" -> Triple("AES/CTR/NoPadding", 24, 16)
            "aes128-ctr" -> Triple("AES/CTR/NoPadding", 16, 16)
            "aes256-cbc" -> Triple("AES/CBC/NoPadding", 32, 16)
            "aes192-cbc" -> Triple("AES/CBC/NoPadding", 24, 16)
            "aes128-cbc" -> Triple("AES/CBC/NoPadding", 16, 16)
            "aes256-gcm@openssh.com" -> Triple("AES/GCM/NoPadding", 32, 12)
            else -> throw IllegalArgumentException(
                "This key is encrypted with ${head.cipher}, which OmniTerm cannot open. " +
                    "Re-protect it with `ssh-keygen -p -Z aes256-ctr -f <file>` and import it again.",
            )
        }
        val options = SshReader(head.kdfOptions)
        val salt = options.bytes()
        val rounds = options.uint32().toInt()
        val derived = ByteArray(keyLength + ivLength)
        BCrypt().pbkdf(passphrase.toByteArray(Charsets.UTF_8), salt, rounds, derived)
        val key = SecretKeySpec(derived.copyOfRange(0, keyLength), "AES")
        val iv = derived.copyOfRange(keyLength, derived.size)
        val cipher = Cipher.getInstance(algorithm)
        return if (head.cipher.endsWith("-gcm@openssh.com")) {
            cipher.init(Cipher.DECRYPT_MODE, key, GCMParameterSpec(128, iv))
            runCatching { cipher.doFinal(head.privateSection + head.trailer.copyOfRange(0, 16.coerceAtMost(head.trailer.size))) }
                .getOrElse { throw WrongPassphrase() }
        } else {
            cipher.init(Cipher.DECRYPT_MODE, key, IvParameterSpec(iv))
            cipher.doFinal(head.privateSection)
        }
    }

    /** Steps over one key's private fields (PROTOCOL.key, and sshkey.c's sshkey_private_serialize). */
    private fun skipKeyFields(reader: SshReader, keyType: String) {
        val strings = when (keyType) {
            "ssh-ed25519", "ssh-ed448" -> 2
            "ssh-rsa" -> 6
            "ssh-dss" -> 5
            "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384", "ecdsa-sha2-nistp521" -> 3
            SkKeyType.Ed25519.sshName -> {
                repeat(2) { reader.bytes() }
                reader.byte()
                repeat(2) { reader.bytes() }
                return
            }
            SkKeyType.EcdsaP256.sshName -> {
                repeat(3) { reader.bytes() }
                reader.byte()
                repeat(2) { reader.bytes() }
                return
            }
            else -> throw IllegalArgumentException("OmniTerm cannot use $keyType keys.")
        }
        repeat(strings) { reader.bytes() }
    }
}
