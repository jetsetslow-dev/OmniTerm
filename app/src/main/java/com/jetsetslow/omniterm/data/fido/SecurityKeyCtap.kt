package com.jetsetslow.omniterm.data.fido

import com.jetsetslow.omniterm.data.ssh.SecurityKeyAssertion
import com.jetsetslow.omniterm.data.ssh.SecurityKeySignRequest
import com.jetsetslow.omniterm.data.ssh.SkKey
import com.jetsetslow.omniterm.data.ssh.SkKeyType
import com.yubico.yubikit.core.application.CommandState
import com.yubico.yubikit.core.fido.CtapException
import com.yubico.yubikit.fido.ctap.ClientPin
import com.yubico.yubikit.fido.ctap.Ctap2Session
import com.yubico.yubikit.fido.ctap.PinUvAuthProtocolV1
import com.yubico.yubikit.fido.ctap.PinUvAuthProtocolV2
import com.yubico.yubikit.fido.webauthn.AuthenticatorData
import java.nio.ByteBuffer
import java.security.MessageDigest
import java.security.SecureRandom

/**
 * The two things OmniTerm asks of a FIDO2 security key, the way OpenSSH's sk-usbhid does: make an
 * SSH key ([create], `ssh-keygen -t ed25519-sk`) and sign a sign-in with one ([sign]).
 */
object SecurityKeyCtap {
    /** The security key wants its PIN; [wrongPin] when the one given was refused. */
    class PinNeeded(val wrongPin: Boolean, val retries: Int?) : Exception()

    /** Why the security key could not do it, as the user should read it. */
    class Failure(message: String) : Exception(message)

    fun sign(session: Ctap2Session, request: SecurityKeySignRequest, pin: CharArray?, state: CommandState): SecurityKeyAssertion {
        val key = request.key
        val options = buildMap<String, Any> {
            if (!key.requiresTouch) put("up", false)
        }
        val auth = authorise(session, pin, ClientPin.PIN_PERMISSION_GA, key.application, request.clientDataHash, key.requiresPin)
        val assertion = run(session, pin) {
            session.getAssertions(
                key.application,
                request.clientDataHash,
                listOf(mapOf("type" to "public-key", "id" to key.keyHandle)),
                null,
                (options + auth.options).ifEmpty { null },
                auth.param,
                auth.protocol,
                state,
            ).first()
        }
        return SecurityKeyAssertion(assertion.authenticatorData, assertion.signature)
    }

    fun create(
        session: Ctap2Session,
        type: SkKeyType,
        requirePin: Boolean,
        pin: CharArray?,
        state: CommandState,
        application: String = SkKey.DEFAULT_APPLICATION,
    ): SkKey {
        val info = session.cachedInfo
        // CTAP 2.0 keys may not list their algorithms; those that do and lack this one say so here.
        if (info.algorithms.isNotEmpty() && info.algorithms.none { it.alg == type.coseAlgorithm }) {
            throw Failure(
                if (type == SkKeyType.Ed25519) {
                    "This security key cannot make Ed25519 keys. Choose ECDSA instead."
                } else {
                    "This security key cannot make ECDSA keys."
                },
            )
        }
        if (requirePin && info.options["clientPin"] != true && info.options["uv"] != true) {
            throw Failure("This security key has no PIN. Set one with its maker's app first, or turn off Require PIN.")
        }
        val clientDataHash = MessageDigest.getInstance("SHA-256").digest(ByteArray(32).also(SecureRandom()::nextBytes))
        val auth = authorise(session, pin, ClientPin.PIN_PERMISSION_MC, application, clientDataHash, requirePin)
        val credential = run(session, pin) {
            session.makeCredential(
                clientDataHash,
                mapOf("id" to application, "name" to application),
                // OpenSSH's non-resident keys: a zero user id named "openssh".
                mapOf("id" to ByteArray(32), "name" to "openssh", "displayName" to "openssh"),
                listOf(mapOf("type" to "public-key", "alg" to type.coseAlgorithm)),
                null,
                null,
                auth.options.ifEmpty { null },
                auth.param,
                auth.protocol,
                null,
                state,
            )
        }
        val attested = AuthenticatorData.parseFrom(ByteBuffer.wrap(credential.authenticatorData)).attestedCredentialData
            ?: throw Failure("The security key made no key.")
        val flags = SkKey.USER_PRESENCE_REQUIRED or if (requirePin) SkKey.USER_VERIFICATION_REQUIRED else 0
        return SkKey(type, publicKey(type, attested.cosePublicKey), application, flags, attested.credentialId)
    }

    /** A COSE public key as SSH writes it: Ed25519's 32 bytes, or an uncompressed P-256 point. */
    internal fun publicKey(type: SkKeyType, cose: Map<Int, *>): ByteArray {
        val x = cose[-2] as? ByteArray ?: throw Failure("The security key's public key is incomplete.")
        return when (type) {
            SkKeyType.Ed25519 -> x.also { if (it.size != 32) throw Failure("The security key's public key is the wrong size.") }
            SkKeyType.EcdsaP256 -> {
                val y = cose[-3] as? ByteArray ?: throw Failure("The security key's public key is incomplete.")
                byteArrayOf(4) + x + y
            }
        }
    }

    private class Auth(val param: ByteArray?, val protocol: Int?, val options: Map<String, Any>)

    /**
     * How to vouch for the user: with a token from [pin] when given; else, when [verify] is needed,
     * the key's own fingerprint reader if it has one, or a request for the PIN.
     */
    private fun authorise(
        session: Ctap2Session,
        pin: CharArray?,
        permission: Int,
        application: String,
        clientDataHash: ByteArray,
        verify: Boolean,
    ): Auth {
        val info = session.cachedInfo
        if (pin != null && ClientPin.isSupported(info)) {
            val protocol = if (2 in info.pinUvAuthProtocols) PinUvAuthProtocolV2() else PinUvAuthProtocolV1()
            val clientPin = ClientPin(session, protocol)
            val token = try {
                clientPin.getPinToken(pin, permission, application)
            } catch (e: CtapException) {
                throw failure(e, clientPin)
            }
            return Auth(protocol.authenticate(token, clientDataHash), protocol.version, emptyMap())
        }
        if (!verify) return Auth(null, null, emptyMap())
        if (info.options["uv"] == true) return Auth(null, null, mapOf("uv" to true))
        throw PinNeeded(wrongPin = false, retries = null)
    }

    private fun <T> run(session: Ctap2Session, pin: CharArray?, block: () -> T): T = try {
        block()
    } catch (e: CtapException) {
        if (e.ctapError == CtapException.ERR_PUAT_REQUIRED && pin == null) throw PinNeeded(wrongPin = false, retries = null)
        throw failure(e, null)
    }

    private fun failure(e: CtapException, clientPin: ClientPin?): Exception = when (e.ctapError) {
        CtapException.ERR_PIN_INVALID ->
            PinNeeded(wrongPin = true, retries = clientPin?.let { runCatching { it.pinRetries.count }.getOrNull() })
        CtapException.ERR_PIN_BLOCKED ->
            Failure("This security key's PIN is blocked after too many wrong tries. Reset the key with its maker's app.")
        CtapException.ERR_PIN_AUTH_BLOCKED ->
            Failure("Too many wrong PINs. Unplug the security key or take it away, then try again.")
        CtapException.ERR_PIN_NOT_SET ->
            Failure("This security key has no PIN. Set one with its maker's app first.")
        CtapException.ERR_NO_CREDENTIALS, CtapException.ERR_INVALID_CREDENTIAL ->
            Failure("This security key does not hold this SSH key. Use the security key the SSH key was made with.")
        CtapException.ERR_OPERATION_DENIED, CtapException.ERR_USER_ACTION_TIMEOUT, CtapException.ERR_ACTION_TIMEOUT ->
            Failure("The security key was not touched in time. Try again.")
        CtapException.ERR_KEEPALIVE_CANCEL -> Failure("Cancelled.")
        CtapException.ERR_UNSUPPORTED_ALGORITHM -> Failure("This security key cannot make this kind of key.")
        CtapException.ERR_UV_BLOCKED, CtapException.ERR_UV_INVALID ->
            Failure("The security key did not recognise you. Try again, or use its PIN.")
        else -> Failure("The security key refused: ${e.errorName}.")
    }
}
