package com.jetsetslow.omniterm

import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyPermanentlyInvalidatedException
import android.security.keystore.KeyProperties
import androidx.biometric.BiometricManager
import androidx.biometric.BiometricPrompt
import androidx.core.content.ContextCompat
import androidx.fragment.app.FragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.lang.ref.WeakReference
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey

/** Android counterpart of Kotlin's BiometricCryptoGate, including its per-use Keystore challenge.
 *
 * local_auth cannot request BIOMETRIC_STRONG alone or supply a CryptoObject, and adds its own
 * prompt heading/description. This bridge keeps the shipped app's policy and exact prompt text.
 * The pending result belongs to the retained engine; a replacement Activity rebinds the callback
 * without replacing the cipher authorized by the system or starting a second authentication.
 */
object BiometricBridge {
    private const val KEY_ALIAS = "omniterm_biometric_gate_key"
    private var host = WeakReference<FragmentActivity>(null)
    private var engine = WeakReference<FlutterEngine>(null)
    private var pending: MethodChannel.Result? = null
    private var prompt: BiometricPrompt? = null

    fun register(flutterEngine: FlutterEngine, activity: FragmentActivity) {
        if (engine.get() !== flutterEngine) cancel()
        engine = WeakReference(flutterEngine)
        host = WeakReference(activity)
        pending?.let { prompt = createPrompt(activity, it) }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "omniterm/biometrics")
            .setMethodCallHandler { call, result ->
                val current = host.get()
                if (current == null || current.isFinishing || current.isDestroyed) {
                    result.error("unavailable", "Biometric authentication is unavailable.", null)
                    return@setMethodCallHandler
                }
                when (call.method) {
                    "isAvailable" -> result.success(canAuthenticate(current))
                    "authenticate" -> authenticate(current, call.argument<String>("reason"), result)
                    "cancel" -> { cancel(); result.success(null) }
                    else -> result.notImplemented()
                }
            }
    }

    fun onHostFinished(activity: FragmentActivity) {
        if (host.get() === activity) {
            cancel()
            host.clear()
        }
    }

    private fun canAuthenticate(activity: FragmentActivity) =
        BiometricManager.from(activity).canAuthenticate(BiometricManager.Authenticators.BIOMETRIC_STRONG) ==
            BiometricManager.BIOMETRIC_SUCCESS

    private fun authenticate(activity: FragmentActivity, reason: String?, result: MethodChannel.Result) {
        // Do not replace a live callback/cipher when auto-prompt and a button arrive together.
        if (pending != null) {
            result.error("in_progress", "Biometric authentication is already open.", null)
            return
        }
        if (!canAuthenticate(activity)) {
            result.error("unavailable", "Set up a strong biometric in your phone settings, or enter your OmniTerm PIN.", null)
            return
        }
        val title = reason ?: "Unlock OmniTerm"
        val subtitle = when (title) {
            "Verify Biometrics" -> "Authenticate to enable biometric unlock"
            "Authenticate to save settings" -> "Confirm it's you"
            "Authenticate for sudo" -> "Confirm to run the privileged action"
            else -> "Authenticate to continue"
        }
        val cipher = runCatching { initCipher() }.recoverCatching {
            if (it !is KeyPermanentlyInvalidatedException) throw it
            KeyStore.getInstance("AndroidKeyStore").apply { load(null); deleteEntry(KEY_ALIAS) }
            initCipher()
        }.getOrElse {
            result.error("unavailable", "Could not prepare biometric authentication. Enter your OmniTerm PIN.", null)
            return
        }
        pending = result
        prompt = createPrompt(activity, result)
        val info = BiometricPrompt.PromptInfo.Builder()
            .setTitle(title)
            .setSubtitle(subtitle)
            .setAllowedAuthenticators(BiometricManager.Authenticators.BIOMETRIC_STRONG)
            .setNegativeButtonText("Cancel")
            .build()
        runCatching { prompt!!.authenticate(info, BiometricPrompt.CryptoObject(cipher)) }
            .onFailure { finish(result, "Could not open biometric authentication. Retry or enter your OmniTerm PIN.") }
    }

    private fun createPrompt(activity: FragmentActivity, result: MethodChannel.Result) = BiometricPrompt(
        activity,
        ContextCompat.getMainExecutor(activity),
        object : BiometricPrompt.AuthenticationCallback() {
            override fun onAuthenticationSucceeded(auth: BiometricPrompt.AuthenticationResult) {
                if (pending !== result) return
                val authenticated = runCatching {
                    auth.cryptoObject?.cipher?.doFinal(byteArrayOf(0x4f, 0x6d, 0x6e, 0x69))?.isNotEmpty() == true
                }.getOrDefault(false)
                if (authenticated) {
                    pending = null
                    prompt = null
                    result.success(true)
                } else {
                    finish(result, "Biometric verification failed. Retry or enter your OmniTerm PIN.")
                }
            }

            override fun onAuthenticationError(code: Int, message: CharSequence) {
                if (pending !== result) return
                if (code == BiometricPrompt.ERROR_USER_CANCELED || code == BiometricPrompt.ERROR_CANCELED ||
                    code == BiometricPrompt.ERROR_NEGATIVE_BUTTON) {
                    pending = null
                    prompt = null
                    result.success(false)
                } else {
                    finish(result, if (code == BiometricPrompt.ERROR_LOCKOUT || code == BiometricPrompt.ERROR_LOCKOUT_PERMANENT) {
                        "Biometrics are locked. Unlock your phone and retry, or enter your OmniTerm PIN."
                    } else {
                        "Biometric authentication is unavailable. Retry or enter your OmniTerm PIN."
                    })
                }
            }
        },
    )

    private fun finish(result: MethodChannel.Result, message: String) {
        if (pending !== result) return
        pending = null
        prompt = null
        result.error("unavailable", message, null)
    }

    private fun cancel() {
        val result = pending
        pending = null
        prompt?.cancelAuthentication()
        prompt = null
        result?.success(false)
    }

    private fun initCipher() = Cipher.getInstance("AES/GCM/NoPadding").apply {
        init(Cipher.ENCRYPT_MODE, getOrCreateKey())
    }

    private fun getOrCreateKey(): SecretKey {
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (store.getKey(KEY_ALIAS, null) as? SecretKey)?.let { return it }
        val spec = KeyGenParameterSpec.Builder(KEY_ALIAS, KeyProperties.PURPOSE_ENCRYPT)
            .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
            .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
            .setRandomizedEncryptionRequired(true)
            .setUserAuthenticationRequired(true)
        if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.R) {
            spec.setUserAuthenticationParameters(0, KeyProperties.AUTH_BIOMETRIC_STRONG)
        } else {
            @Suppress("DEPRECATION")
            spec.setUserAuthenticationValidityDurationSeconds(-1)
        }
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").run {
            init(spec.build())
            generateKey()
        }
    }
}
