package com.jetsetslow.omniterm.data.ssh

import com.jcraft.jsch.JSch
import com.jcraft.jsch.KeyPair
import java.io.ByteArrayOutputStream

/** A key ready to save: what is stored as its private part, its public line, type and fingerprint. */
data class PreparedSshKey(
    val privateKey: String,
    val publicKey: String,
    val keyType: String,
    val fingerprint: String,
    /** Its OpenSSH certificate line, or "" without one. */
    val certificate: String,
)

/** Checks and normalises the keys and certificates users paste or pick. */
object SshKeyMaterial {
    /**
     * [privateKey] (with [publicKey] and [certificate] when given) ready to save. A key protected by
     * a passphrase is opened with [passphrase] and saved without it: OmniTerm encrypts saved keys
     * itself, and nothing asks for a passphrase when connecting. Throws IllegalArgumentException
     * saying what is wrong.
     */
    fun prepare(privateKey: String, publicKey: String = "", passphrase: String = "", certificate: String = ""): PreparedSshKey {
        val text = privateKey.trim().replace("\r\n", "\n").replace("\r", "\n")
        if (looksLikePublicKey(text)) {
            throw IllegalArgumentException("That's a public key. Paste the matching PRIVATE key (the file without the .pub extension).")
        }
        if (!text.contains("PRIVATE KEY")) {
            throw IllegalArgumentException(
                "That doesn't look like a private key. Include the \"-----BEGIN ... PRIVATE KEY-----\" " +
                    "and \"-----END ... PRIVATE KEY-----\" lines.",
            )
        }
        var comment = ""
        val stored: String
        val blob: ByteArray
        if (OpenSshKeyFile.isOpenSshKey(text)) {
            val contents = OpenSshKeyFile.read(text, passphrase)
            comment = contents.comment
            stored = if (OpenSshKeyFile.isEncrypted(text)) OpenSshKeyFile.write(contents) else text
            blob = contents.publicBlob
            if (SkKeyType.of(contents.keyType) == null) jschKeyBlob(stored, "")
        } else {
            val opened = openWithJsch(text, passphrase)
            stored = opened.first
            blob = opened.second
        }
        val publicLine = publicKey.trim().takeIf { it.isNotEmpty() }?.let { given ->
            val givenBlob = SshWire.publicBlob(given)
                ?: throw IllegalArgumentException("The public key is not a valid OpenSSH public key line. Leave it blank to derive it.")
            if (!givenBlob.contentEquals(blob)) {
                throw IllegalArgumentException("The public key does not match the private key. Leave it blank to derive it.")
            }
            given.lines().first().trim()
        } ?: SshWire.publicLine(blob, comment)
        return PreparedSshKey(
            privateKey = stored,
            publicKey = publicLine,
            keyType = typeLabel(SshWire.algorithm(blob)),
            fingerprint = SshWire.fingerprint(blob),
            certificate = checkedCertificate(certificate, blob),
        )
    }

    /**
     * [certificate] trimmed to its line, after checking it certifies the key with public blob
     * [keyBlob] for signing in as a user; "" when blank. Throws IllegalArgumentException otherwise.
     */
    fun checkedCertificate(certificate: String, keyBlob: ByteArray?): String {
        val line = certificate.trim().lines().firstOrNull { it.isNotBlank() }?.trim() ?: return ""
        val parsed = SshCertificate.parse(line)
        SshCertificate.mismatch(parsed, keyBlob)?.let { throw IllegalArgumentException(it) }
        return line
    }

    /** The public blob of a saved key: from its public line, else from the key itself. */
    fun publicBlob(privateKey: String, publicKey: String): ByteArray? =
        SshWire.publicBlob(publicKey) ?: runCatching { prepare(privateKey).let { SshWire.publicBlob(it.publicKey) } }.getOrNull()

    /** The label OmniTerm shows for a key of SSH type [algorithm]. */
    fun typeLabel(algorithm: String): String = SkKeyType.of(algorithm)?.label ?: when {
        algorithm == "ssh-ed25519" -> "ED25519"
        algorithm == "ssh-ed448" -> "ED448"
        algorithm == "ssh-rsa" -> "RSA"
        algorithm == "ssh-dss" -> "DSA"
        algorithm.startsWith("ecdsa-") -> "ECDSA"
        else -> algorithm
    }

    /** A PEM or PKCS#8 key opened by JSch: stored without its passphrase, and its public blob. */
    private fun openWithJsch(text: String, passphrase: String): Pair<String, ByteArray> {
        val keyPair = load(text)
        try {
            if (!keyPair.isEncrypted) return text to keyPair.publicKeyBlob
            if (passphrase.isEmpty()) throw OpenSshKeyFile.PassphraseNeeded()
            if (!keyPair.decrypt(passphrase.toByteArray(Charsets.UTF_8))) throw OpenSshKeyFile.WrongPassphrase()
            val out = ByteArrayOutputStream()
            try {
                keyPair.writePrivateKey(out)
            } catch (_: UnsupportedOperationException) {
                throw IllegalArgumentException(
                    "OmniTerm cannot store this kind of key without its passphrase. Convert it with " +
                        "`ssh-keygen -p -f <file>` (which writes OpenSSH's own format) and import it again.",
                )
            }
            val stored = out.toString(Charsets.UTF_8.name())
            return stored to jschKeyBlob(stored, "")
        } finally {
            keyPair.dispose()
        }
    }

    /** Checks JSch can sign with [text] and returns its public blob. */
    private fun jschKeyBlob(text: String, passphrase: String): ByteArray {
        val keyPair = load(text)
        try {
            if (keyPair.isEncrypted && !keyPair.decrypt(passphrase.toByteArray(Charsets.UTF_8))) throw OpenSshKeyFile.WrongPassphrase()
            return keyPair.publicKeyBlob
        } finally {
            keyPair.dispose()
        }
    }

    private fun load(text: String): KeyPair = try {
        KeyPair.load(JSch(), (text.trim() + "\n").toByteArray(Charsets.UTF_8), null)
    } catch (e: Exception) {
        // Never leak JSch's raw "invalid privatekey: [B@…" byte-array dump.
        throw IllegalArgumentException(
            e.message?.takeUnless { it.contains("[B@") }?.let { "Invalid private key: $it" }
                ?: "Invalid private key — re-copy the full key text, including the BEGIN/END lines.",
            e,
        )
    }
}
