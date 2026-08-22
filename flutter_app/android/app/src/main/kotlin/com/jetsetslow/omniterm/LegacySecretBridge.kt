package com.jetsetslow.omniterm

import android.util.Base64
import android.util.Log
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * Decrypts credentials written by the Kotlin app's `SecretStore` during in-place upgrade.
 *
 * The old app encrypted **every** stored credential — server, sudo and proxy passwords, imported
 * private keys, credential-profile and share passwords — under an AES-GCM key generated inside the
 * Android Keystore. That key is non-exportable by design, so the Dart port cannot use it and writes
 * its own `enc:v2:` values instead. Without this bridge, an updating user would open the app and
 * find every saved secret blank, because `SecretStore.decrypt` returns null on failure by contract.
 *
 * So this exists to be read from exactly once per value: Dart calls it for anything still tagged
 * `enc:v1:`, re-encrypts the plaintext under its own key, and writes the `enc:v2:` form back. The
 * migration is per-value and transparent, and the Keystore key is never exported — only used.
 *
 * Every constant here must match `data/SecretStore.kt` in the Kotlin app exactly. They are not
 * choices this file gets to make: they describe data already on disk.
 */
object LegacySecretBridge {
    const val CHANNEL = "com.jetsetslow.omniterm/legacy_secrets"

    private const val ANDROID_KEYSTORE = "AndroidKeyStore"

    /** The alias the Kotlin app generated its key under. Changing this loses every saved secret. */
    private const val KEY_ALIAS = "omniterm_local_secret_key"

    private const val TRANSFORMATION = "AES/GCM/NoPadding"
    private const val LEGACY_PREFIX = "enc:v1:"
    private const val GCM_TAG_BITS = 128
    private const val IV_BYTES = 12

    private const val TAG = "LegacySecretBridge"

    fun register(engine: FlutterEngine) {
        MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "decryptLegacy" -> result.success(decrypt(call.arguments as? String))
                // Lets the Dart side skip the channel entirely on a device that never ran the old
                // app, rather than paying a platform round trip per secret to learn there is no key.
                "hasLegacyKey" -> result.success(hasLegacyKey())
                else -> result.notImplemented()
            }
        }
    }

    /**
     * Returns the plaintext of an `enc:v1:` [value], or null if it cannot be read.
     *
     * Null is returned rather than an error for every failure mode — no key (a fresh install), a
     * key the user invalidated by removing their device lock, or ciphertext that fails its GCM tag.
     * The Dart side treats null as "leave it alone", which keeps an unreadable value on disk instead
     * of overwriting it with a blank. A future OS or app version might still recover it; an
     * overwrite is final.
     */
    fun decrypt(value: String?): String? {
        if (value.isNullOrEmpty() || !value.startsWith(LEGACY_PREFIX)) return null
        return runCatching {
            val key = loadKey() ?: return null
            val payload = Base64.decode(value.removePrefix(LEGACY_PREFIX), Base64.NO_WRAP)
            // A payload of exactly IV_BYTES has no ciphertext at all; anything shorter cannot even
            // supply the IV. Either way `copyOfRange` below would be meaningless.
            require(payload.size > IV_BYTES) { "payload too short" }
            val iv = payload.copyOfRange(0, IV_BYTES)
            val ciphertext = payload.copyOfRange(IV_BYTES, payload.size)
            val cipher = Cipher.getInstance(TRANSFORMATION)
            cipher.init(Cipher.DECRYPT_MODE, key, GCMParameterSpec(GCM_TAG_BITS, iv))
            String(cipher.doFinal(ciphertext), Charsets.UTF_8)
        }.onFailure {
            // The class name only — never the value, and never the exception message, which for a
            // padding or tag failure can carry ciphertext detail.
            Log.w(TAG, "Legacy secret could not be decrypted: ${it.javaClass.simpleName}")
        }.getOrNull()
    }

    /**
     * The legacy key if this device has one.
     *
     * Deliberately never *creates* one, unlike the Kotlin original: a fresh install has no legacy
     * data, and generating a key here would produce one that can only ever decrypt nothing.
     */
    private fun loadKey(): SecretKey? = runCatching {
        KeyStore.getInstance(ANDROID_KEYSTORE).apply { load(null) }.getKey(KEY_ALIAS, null) as? SecretKey
    }.getOrNull()

    fun hasLegacyKey(): Boolean = loadKey() != null
}
