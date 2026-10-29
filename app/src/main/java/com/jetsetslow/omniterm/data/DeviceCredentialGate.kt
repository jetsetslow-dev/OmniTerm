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
 * privileged action while App Lock is off. It unlocks no secret of its own. On Android 11 and later,
 * like [BiometricCryptoGate], it counts as passed only once a Keystore key bound to that one prompt
 * has been used.
 *
 * Android 7 to 10 cannot unlock a per-use key with the screen lock, and a key that stays open for a
 * while after any unlock is weaker than the check it would back. They show the system's "Confirm
 * your PIN" screen and go by its answer.
 */
object DeviceCredentialGate {
    private const val ANDROID_KEYSTORE = "AndroidKeyStore"
    private const val KEY_ALIAS = "omniterm_device_credential_gate_key"
    private const val TRANSFORMATION = "AES/GCM/NoPadding"
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
            confirmCredential(activity, title, subtitle, onAuthenticated)
        }
    }

    @RequiresApi(Build.VERSION_CODES.R)
    private fun promptWithBoundKey(activity: AppCompatActivity, title: String, subtitle: String, onAuthenticated: () -> Unit) {
        val cipher = cipherOrNull() ?: return
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

    private fun confirmCredential(activity: AppCompatActivity, title: String, subtitle: String, onAuthenticated: () -> Unit) {
        val intent = activity.getSystemService(KeyguardManager::class.java)
            ?.createConfirmDeviceCredentialIntent(title, subtitle) ?: return
        var launcher: ActivityResultLauncher<Intent>? = null
        launcher = activity.activityResultRegistry.register(
            "omniterm.deviceCredential.${requests.incrementAndGet()}",
            ActivityResultContracts.StartActivityForResult(),
        ) { result ->
            launcher?.unregister()
            if (result.resultCode == Activity.RESULT_OK) onAuthenticated()
        }
        launcher.launch(intent)
    }

    /** True when [cipher] works, which the Keystore allows only after the unlock its key needs. */
    private fun opens(cipher: Cipher?): Boolean =
        runCatching { cipher?.doFinal(challenge)?.isNotEmpty() == true }.getOrDefault(false)

    /**
     * A cipher on the gate's key. A key the system has invalidated, because the screen lock or the
     * fingerprints changed, is replaced. Null when the Keystore refuses it.
     */
    @RequiresApi(Build.VERSION_CODES.R)
    private fun cipherOrNull(): Cipher? = runCatching { initCipher() }
        .recoverCatching {
            if (it !is KeyPermanentlyInvalidatedException) throw it
            KeyStore.getInstance(ANDROID_KEYSTORE).apply { load(null) }.deleteEntry(KEY_ALIAS)
            initCipher()
        }
        .getOrNull()

    @RequiresApi(Build.VERSION_CODES.R)
    private fun initCipher(): Cipher =
        Cipher.getInstance(TRANSFORMATION).apply { init(Cipher.ENCRYPT_MODE, keyOrCreate()) }

    @RequiresApi(Build.VERSION_CODES.R)
    private fun keyOrCreate(): SecretKey {
        val keyStore = KeyStore.getInstance(ANDROID_KEYSTORE).apply { load(null) }
        (keyStore.getKey(KEY_ALIAS, null) as? SecretKey)?.let { return it }
        val spec = KeyGenParameterSpec.Builder(KEY_ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
            .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
            .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
            .setUserAuthenticationRequired(true)
            .setUserAuthenticationParameters(0, KeyProperties.AUTH_BIOMETRIC_STRONG or KeyProperties.AUTH_DEVICE_CREDENTIAL)
            .build()
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, ANDROID_KEYSTORE)
            .apply { init(spec) }
            .generateKey()
    }
}
