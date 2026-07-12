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

object BiometricCryptoGate {
    private const val ANDROID_KEYSTORE = "AndroidKeyStore"
    private const val KEY_ALIAS = "omniterm_biometric_gate_key"
    private const val TRANSFORMATION = "AES/GCM/NoPadding"
    private val challenge = byteArrayOf(0x4f, 0x6d, 0x6e, 0x69)

    fun canAuthenticate(activity: AppCompatActivity): Boolean =
        BiometricManager.from(activity).canAuthenticate(BiometricManager.Authenticators.BIOMETRIC_STRONG) ==
            BiometricManager.BIOMETRIC_SUCCESS

    fun authenticate(
        activity: AppCompatActivity,
        title: String,
        subtitle: String,
        onAuthenticated: () -> Unit,
        onUnavailable: () -> Unit = {},
        onError: () -> Unit = {},
    ) {
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

        val prompt = BiometricPrompt(
            activity,
            ContextCompat.getMainExecutor(activity),
            object : BiometricPrompt.AuthenticationCallback() {
                override fun onAuthenticationSucceeded(result: BiometricPrompt.AuthenticationResult) {
                    val resultCipher = result.cryptoObject?.cipher
                    val ok = runCatching {
                        resultCipher?.doFinal(challenge)?.isNotEmpty() == true
                    }.getOrDefault(false)
                    if (ok) onAuthenticated() else onError()
                }

                override fun onAuthenticationError(errorCode: Int, errString: CharSequence) {
                    onError()
                }
            },
        )
        val info = BiometricPrompt.PromptInfo.Builder()
            .setTitle(title)
            .setSubtitle(subtitle)
            .setAllowedAuthenticators(BiometricManager.Authenticators.BIOMETRIC_STRONG)
            .setNegativeButtonText("Cancel")
            .build()
        prompt.authenticate(info, BiometricPrompt.CryptoObject(cipher))
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
