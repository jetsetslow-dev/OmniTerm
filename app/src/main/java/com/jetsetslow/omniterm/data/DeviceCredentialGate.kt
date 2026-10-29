package com.jetsetslow.omniterm.data

import android.app.Activity
import android.app.KeyguardManager
import android.content.Context
import android.content.Intent
import android.os.Build
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyPermanentlyInvalidatedException
import android.security.keystore.KeyProperties
import androidx.activity.result.ActivityResultLauncher
import androidx.activity.result.contract.ActivityResultContracts
import androidx.annotation.RequiresApi
import androidx.appcompat.app.AppCompatActivity
import androidx.biometric.BiometricManager
import androidx.biometric.BiometricPrompt
import androidx.core.content.ContextCompat
import java.security.KeyStore
import java.util.concurrent.atomic.AtomicInteger
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey

/**
 * The phone's own lock (fingerprint, face, or its PIN, pattern or password) as the check before a
 * privileged action while App Lock is off. It unlocks no secret of its own, but like
 * [BiometricCryptoGate] it counts the check as passed only once a Keystore key that needs that
 * unlock has been used.
 *
 * Android 11 and later bind the key to each prompt. Android 7 to 10 cannot offer the screen lock
 * with a bound key, so they show the system's "Confirm your PIN" screen and use a key that opens for
 * a few seconds after it.
 */
object DeviceCredentialGate {
    private const val ANDROID_KEYSTORE = "AndroidKeyStore"
    private const val PER_USE_KEY_ALIAS = "omniterm_device_credential_gate_key"
    private const val TIMED_KEY_ALIAS = "omniterm_device_credential_timed_key"
    private const val TRANSFORMATION = "AES/GCM/NoPadding"
    private const val UNLOCK_SECONDS = 5
    private val challenge = byteArrayOf(0x4f, 0x6d, 0x6e, 0x69)
    private val requests = AtomicInteger()

    /** True when the phone has a screen lock to ask for; fingerprints and faces need one too. */
    fun isAvailable(context: Context): Boolean =
        context.getSystemService(KeyguardManager::class.java)?.isDeviceSecure == true

    /** Shows the system prompt; [onAuthenticated] runs only when the person unlocks it. */
    fun authenticate(activity: AppCompatActivity, title: String, subtitle: String, onAuthenticated: () -> Unit) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            promptWithBoundKey(activity, title, subtitle, onAuthenticated)
        } else {
            confirmThenUseTimedKey(activity, title, subtitle, onAuthenticated)
        }
    }

    @RequiresApi(Build.VERSION_CODES.R)
    private fun promptWithBoundKey(activity: AppCompatActivity, title: String, subtitle: String, onAuthenticated: () -> Unit) {
        val cipher = cipherOrNull(PER_USE_KEY_ALIAS) ?: return
        val prompt = BiometricPrompt(
            activity,
            ContextCompat.getMainExecutor(activity),
            object : BiometricPrompt.AuthenticationCallback() {
                override fun onAuthenticationSucceeded(result: BiometricPrompt.AuthenticationResult) {
                    if (opens(result.cryptoObject?.cipher)) onAuthenticated()
                }
            },
        )
        val info = BiometricPrompt.PromptInfo.Builder()
            .setTitle(title)
            .setSubtitle(subtitle)
            .setAllowedAuthenticators(
                BiometricManager.Authenticators.BIOMETRIC_STRONG or BiometricManager.Authenticators.DEVICE_CREDENTIAL,
            )
            .build()
        // A prompt already showing refuses a second one; the dialog's Unlock button asks again.
        runCatching { prompt.authenticate(info, BiometricPrompt.CryptoObject(cipher)) }
    }

    private fun confirmThenUseTimedKey(activity: AppCompatActivity, title: String, subtitle: String, onAuthenticated: () -> Unit) {
        val intent = activity.getSystemService(KeyguardManager::class.java)
            ?.createConfirmDeviceCredentialIntent(title, subtitle) ?: return
        // Creates the key, or replaces one the system invalidated. The cipher itself is refused
        // until the person unlocks below.
        cipherOrNull(TIMED_KEY_ALIAS)
        var launcher: ActivityResultLauncher<Intent>? = null
        launcher = activity.activityResultRegistry.register(
            "omniterm.deviceCredential.${requests.incrementAndGet()}",
            ActivityResultContracts.StartActivityForResult(),
        ) { result ->
            launcher?.unregister()
            if (result.resultCode == Activity.RESULT_OK && opens(cipherOrNull(TIMED_KEY_ALIAS))) onAuthenticated()
        }
        launcher.launch(intent)
    }

    /** True when [cipher] works, which the Keystore allows only after the unlock its key needs. */
    private fun opens(cipher: Cipher?): Boolean =
        runCatching { cipher?.doFinal(challenge)?.isNotEmpty() == true }.getOrDefault(false)

    /**
     * A cipher on [alias]'s key. A key the system has invalidated, because the screen lock or the
     * fingerprints changed, is replaced. Null when the Keystore refuses it, including a timed key
     * whose unlock has run out.
     */
    private fun cipherOrNull(alias: String): Cipher? = runCatching { initCipher(alias) }
        .recoverCatching {
            if (it !is KeyPermanentlyInvalidatedException) throw it
            KeyStore.getInstance(ANDROID_KEYSTORE).apply { load(null) }.deleteEntry(alias)
            initCipher(alias)
        }
        .getOrNull()

    private fun initCipher(alias: String): Cipher =
        Cipher.getInstance(TRANSFORMATION).apply { init(Cipher.ENCRYPT_MODE, keyOrCreate(alias)) }

    private fun keyOrCreate(alias: String): SecretKey {
        val keyStore = KeyStore.getInstance(ANDROID_KEYSTORE).apply { load(null) }
        (keyStore.getKey(alias, null) as? SecretKey)?.let { return it }
        val spec = KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
            .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
            .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
            .setUserAuthenticationRequired(true)
            .apply {
                if (alias == PER_USE_KEY_ALIAS && Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                    setUserAuthenticationParameters(
                        0,
                        KeyProperties.AUTH_BIOMETRIC_STRONG or KeyProperties.AUTH_DEVICE_CREDENTIAL,
                    )
                } else {
                    @Suppress("DEPRECATION")
                    setUserAuthenticationValidityDurationSeconds(UNLOCK_SECONDS)
                }
            }
            .build()
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, ANDROID_KEYSTORE)
            .apply { init(spec) }
            .generateKey()
    }
}
