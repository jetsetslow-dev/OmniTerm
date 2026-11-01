package com.jetsetslow.omniterm

import android.app.Activity
import android.app.KeyguardManager
import android.content.Intent
import android.os.Build
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyPermanentlyInvalidatedException
import android.security.keystore.KeyProperties
import androidx.activity.result.ActivityResultLauncher
import androidx.activity.result.contract.ActivityResultContracts
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
 *
 * It also carries Kotlin's DeviceCredentialGate: the phone's own lock (fingerprint, face, or its
 * PIN, pattern or password) as the check before a privileged action while App Lock is off. It
 * unlocks no secret of its own. On Android 11 and later it counts as passed only once a Keystore key
 * bound to that one prompt has been used. Android 7 to 10 cannot unlock a per-use key with the
 * screen lock, so they show the system's "Confirm your PIN" screen and go by its answer.
 */
object BiometricBridge {
    private const val KEY_ALIAS = "omniterm_biometric_gate_key"
    private const val DEVICE_KEY_ALIAS = "omniterm_device_credential_gate_key"
    private val challenge = byteArrayOf(0x4f, 0x6d, 0x6e, 0x69)
    private var host = WeakReference<FragmentActivity>(null)
    private var engine = WeakReference<FlutterEngine>(null)
    private var pending: MethodChannel.Result? = null
    private var prompt: BiometricPrompt? = null
    private var devicePending: MethodChannel.Result? = null
    private var devicePrompt: BiometricPrompt? = null
    private var deviceConfirm: ActivityResultLauncher<Intent>? = null
    private var deviceConfirmKey: String? = null
    private var deviceRequests = 0

    fun register(flutterEngine: FlutterEngine, activity: FragmentActivity) {
        if (engine.get() !== flutterEngine) cancel()
        engine = WeakReference(flutterEngine)
        host = WeakReference(activity)
        pending?.let { prompt = createPrompt(activity, it) }
        devicePending?.let { result ->
            // A "Confirm your PIN" screen still open reports to the replacement Activity's registry.
            val confirmKey = deviceConfirmKey
            if (confirmKey != null) deviceConfirm = registerDeviceConfirm(activity, confirmKey, result)
            else devicePrompt = createDevicePrompt(activity, result)
        }
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
                    "isDeviceSecure" -> result.success(
                        current.getSystemService(KeyguardManager::class.java)?.isDeviceSecure == true,
                    )
                    "authenticateDevice" -> authenticateDevice(
                        current,
                        call.argument<String>("title").orEmpty(),
                        call.argument<String>("subtitle").orEmpty(),
                        result,
                    )
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
        val cipher = cipherOrNull(KEY_ALIAS) ?: run {
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

    /** The phone's screen lock, as Kotlin's DeviceCredentialGate.authenticate; true once unlocked. */
    private fun authenticateDevice(activity: FragmentActivity, title: String, subtitle: String, result: MethodChannel.Result) {
        // A prompt already showing refuses a second one; the dialog's Unlock button asks again.
        if (devicePending != null) {
            result.success(false)
            return
        }
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) {
            confirmDevice(activity, title, subtitle, result)
            return
        }
        val cipher = cipherOrNull(DEVICE_KEY_ALIAS) ?: run {
            result.success(false)
            return
        }
        devicePending = result
        devicePrompt = createDevicePrompt(activity, result)
        val info = BiometricPrompt.PromptInfo.Builder()
            .setTitle(title)
            .setSubtitle(subtitle)
            .setAllowedAuthenticators(
                BiometricManager.Authenticators.BIOMETRIC_STRONG or BiometricManager.Authenticators.DEVICE_CREDENTIAL,
            )
            .build()
        runCatching { devicePrompt!!.authenticate(info, BiometricPrompt.CryptoObject(cipher)) }
            .onFailure { finishDevice(result, false) }
    }

    /** Android 7 to 10: the system's "Confirm your PIN" screen, as Kotlin's DeviceCredentialGate. */
    private fun confirmDevice(activity: FragmentActivity, title: String, subtitle: String, result: MethodChannel.Result) {
        val intent = activity.getSystemService(KeyguardManager::class.java)
            ?.createConfirmDeviceCredentialIntent(title, subtitle) ?: run {
            result.success(false)
            return
        }
        val key = "omniterm.deviceCredential.${++deviceRequests}"
        devicePending = result
        deviceConfirmKey = key
        deviceConfirm = registerDeviceConfirm(activity, key, result)
        runCatching { deviceConfirm!!.launch(intent) }.onFailure { finishDevice(result, false) }
    }

    private fun registerDeviceConfirm(activity: FragmentActivity, key: String, result: MethodChannel.Result) =
        activity.activityResultRegistry.register(key, ActivityResultContracts.StartActivityForResult()) {
            finishDevice(result, it.resultCode == Activity.RESULT_OK)
        }

    private fun createDevicePrompt(activity: FragmentActivity, result: MethodChannel.Result) = BiometricPrompt(
        activity,
        ContextCompat.getMainExecutor(activity),
        object : BiometricPrompt.AuthenticationCallback() {
            override fun onAuthenticationSucceeded(auth: BiometricPrompt.AuthenticationResult) =
                finishDevice(result, opens(auth.cryptoObject?.cipher))

            // Cancelled, locked out or unavailable alike: nothing runs, and the dialog stays up to
            // ask again or cancel.
            override fun onAuthenticationError(code: Int, message: CharSequence) = finishDevice(result, false)
        },
    )

    private fun finishDevice(result: MethodChannel.Result, unlocked: Boolean) {
        if (devicePending !== result) return
        devicePending = null
        devicePrompt = null
        deviceConfirm?.unregister()
        deviceConfirm = null
        deviceConfirmKey = null
        result.success(unlocked)
    }

    private fun createPrompt(activity: FragmentActivity, result: MethodChannel.Result) = BiometricPrompt(
        activity,
        ContextCompat.getMainExecutor(activity),
        object : BiometricPrompt.AuthenticationCallback() {
            override fun onAuthenticationSucceeded(auth: BiometricPrompt.AuthenticationResult) {
                if (pending !== result) return
                if (opens(auth.cryptoObject?.cipher)) {
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
        devicePrompt?.cancelAuthentication()
        devicePending?.let { finishDevice(it, false) }
    }

    /** True when [cipher] works, which the Keystore allows only after the unlock its key needs. */
    private fun opens(cipher: Cipher?): Boolean =
        runCatching { cipher?.doFinal(challenge)?.isNotEmpty() == true }.getOrDefault(false)

    /**
     * A cipher on [alias]'s key. A key the system has invalidated, because the screen lock or the
     * fingerprints changed, is replaced. Null when the Keystore refuses it.
     */
    private fun cipherOrNull(alias: String): Cipher? = runCatching { initCipher(alias) }
        .recoverCatching {
            if (it !is KeyPermanentlyInvalidatedException) throw it
            KeyStore.getInstance("AndroidKeyStore").apply { load(null); deleteEntry(alias) }
            initCipher(alias)
        }
        .getOrNull()

    private fun initCipher(alias: String) = Cipher.getInstance("AES/GCM/NoPadding").apply {
        init(Cipher.ENCRYPT_MODE, getOrCreateKey(alias))
    }

    private fun getOrCreateKey(alias: String): SecretKey {
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (store.getKey(alias, null) as? SecretKey)?.let { return it }
        val spec = KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_ENCRYPT)
            .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
            .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
            .setRandomizedEncryptionRequired(true)
            .setUserAuthenticationRequired(true)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            // The screen-lock key is only made on Android 11 and later, where a PIN can unlock it.
            spec.setUserAuthenticationParameters(
                0,
                if (alias == DEVICE_KEY_ALIAS) {
                    KeyProperties.AUTH_BIOMETRIC_STRONG or KeyProperties.AUTH_DEVICE_CREDENTIAL
                } else {
                    KeyProperties.AUTH_BIOMETRIC_STRONG
                },
            )
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
