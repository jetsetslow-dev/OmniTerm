package com.jetsetslow.omniterm.data

import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyPermanentlyInvalidatedException
import android.security.keystore.KeyProperties
import androidx.appcompat.app.AppCompatActivity
import androidx.biometric.BiometricManager
import androidx.biometric.BiometricPrompt
import androidx.core.content.ContextCompat
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import java.lang.ref.WeakReference

object BiometricCryptoGate {
    private const val ANDROID_KEYSTORE = "AndroidKeyStore"
    private const val KEY_ALIAS = "omniterm_biometric_gate_key"
    private const val TRANSFORMATION = "AES/GCM/NoPadding"
    private val challenge = byteArrayOf(0x4f, 0x6d, 0x6e, 0x69)

    // Single-flight gate: androidx's BiometricFragment refuses to show a second dialog while one
    // is up, but a concurrent authenticate() still rebinds the activity-scoped client callback and
    // replaces the in-flight CryptoObject with a cipher the framework session never authorized —
    // which would make doFinal() fail after a genuinely successful authentication. Both the lock
    // screen's auto-prompt and its "Use biometrics" button (and any recreation re-trigger) funnel
    // through here, so one in-flight authentication at a time is the correct global invariant.
    private val authInFlight = java.util.concurrent.atomic.AtomicBoolean(false)
    @Volatile private var authHost = WeakReference<AppCompatActivity>(null)

    val isAuthenticationInFlight: Boolean get() = authInFlight.get()

    /**
     * Called when the hosting activity is destroyed while finishing: any system prompt bound to it
     * is gone for good and no further callback can arrive, so drop the in-flight claim rather than
     * leaving biometrics dead until process restart. Configuration changes must NOT call this —
     * androidx restores the live prompt across recreation and its retained callback still fires.
     */
    fun onHostActivityFinished() {
        authInFlight.set(false)
        authHost.clear()
    }

    fun canAuthenticate(activity: AppCompatActivity): Boolean =
        BiometricManager.from(activity).canAuthenticate(BiometricManager.Authenticators.BIOMETRIC_STRONG) ==
            BiometricManager.BIOMETRIC_SUCCESS

    @Synchronized
    fun authenticate(
        activity: AppCompatActivity,
        title: String,
        subtitle: String,
        onAuthenticated: () -> Unit,
        onUnavailable: () -> Unit = {},
        onError: () -> Unit = {},
    ) {
        // Reconstructing BiometricPrompt with the new Activity is how androidx rebinds the
        // callback for an authentication that survived configuration change. Same-Activity
        // double taps remain strict no-ops so they cannot replace the active callback.
        if (authInFlight.get()) {
            if (authHost.get() !== activity) {
                authHost = WeakReference(activity)
                createPrompt(activity, onAuthenticated, onError)
            }
            return
        }
        if (!canAuthenticate(activity)) {
            onUnavailable()
            return
        }
        val cipher = runCatching { initCipher() }
            .recoverCatching {
                if (it is KeyPermanentlyInvalidatedException) {
                    deleteKey()
                    initCipher()
                } else {
                    throw it
                }
            }
            .getOrElse {
                onUnavailable()
                return
            }

        if (!authInFlight.compareAndSet(false, true)) return
        authHost = WeakReference(activity)
        val prompt = createPrompt(activity, onAuthenticated, onError)
        val info = BiometricPrompt.PromptInfo.Builder()
            .setTitle(title)
            .setSubtitle(subtitle)
            .setAllowedAuthenticators(BiometricManager.Authenticators.BIOMETRIC_STRONG)
            .setNegativeButtonText("Cancel")
            .build()
        runCatching { prompt.authenticate(info, BiometricPrompt.CryptoObject(cipher)) }
            .onFailure {
                clearInFlight()
                onUnavailable()
            }
    }

    private fun createPrompt(
        activity: AppCompatActivity,
        onAuthenticated: () -> Unit,
        onError: () -> Unit,
    ): BiometricPrompt =
        BiometricPrompt(
            activity,
            ContextCompat.getMainExecutor(activity),
            object : BiometricPrompt.AuthenticationCallback() {
                override fun onAuthenticationSucceeded(result: BiometricPrompt.AuthenticationResult) {
                    clearInFlight()
                    val resultCipher = result.cryptoObject?.cipher
                    val ok = runCatching {
                        resultCipher?.doFinal(challenge)?.isNotEmpty() == true
                    }.getOrDefault(false)
                    if (ok) onAuthenticated() else onError()
                }

                override fun onAuthenticationError(errorCode: Int, errString: CharSequence) {
                    clearInFlight()
                    onError()
                }
            },
        )

    private fun clearInFlight() {
        authInFlight.set(false)
        authHost.clear()
    }

    private fun initCipher(): Cipher =
        Cipher.getInstance(TRANSFORMATION).apply {
            init(Cipher.ENCRYPT_MODE, getOrCreateKey())
        }

    @Synchronized
    private fun getOrCreateKey(): SecretKey {
        val keyStore = KeyStore.getInstance(ANDROID_KEYSTORE).apply { load(null) }
        (keyStore.getKey(KEY_ALIAS, null) as? SecretKey)?.let { return it }

        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, ANDROID_KEYSTORE)
        val builder = KeyGenParameterSpec.Builder(
            KEY_ALIAS,
            KeyProperties.PURPOSE_ENCRYPT,
        )
            .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
            .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
            .setRandomizedEncryptionRequired(true)
            .setUserAuthenticationRequired(true)
        if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.R) {
            builder.setUserAuthenticationParameters(0, KeyProperties.AUTH_BIOMETRIC_STRONG)
        } else {
            @Suppress("DEPRECATION")
            builder.setUserAuthenticationValidityDurationSeconds(-1)
        }
        generator.init(builder.build())
        return generator.generateKey()
    }

    @Synchronized
    private fun deleteKey() {
        KeyStore.getInstance(ANDROID_KEYSTORE).apply {
            load(null)
            deleteEntry(KEY_ALIAS)
        }
    }
}
