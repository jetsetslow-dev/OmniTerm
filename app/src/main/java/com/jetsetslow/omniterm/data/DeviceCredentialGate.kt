package com.jetsetslow.omniterm.data

import android.app.KeyguardManager
import android.content.Context
import androidx.appcompat.app.AppCompatActivity
import androidx.biometric.BiometricManager
import androidx.biometric.BiometricPrompt
import androidx.core.content.ContextCompat

/**
 * The phone's own lock (fingerprint, face, or its PIN, pattern or password) as the check before a
 * privileged action while App Lock is off. Unlike [BiometricCryptoGate] it unlocks no key: it only
 * asks whoever holds the phone to show they can unlock it.
 */
object DeviceCredentialGate {
    private const val AUTHENTICATORS =
        BiometricManager.Authenticators.BIOMETRIC_WEAK or BiometricManager.Authenticators.DEVICE_CREDENTIAL

    /** True when the phone has a screen lock to ask for; fingerprints and faces need one too. */
    fun isAvailable(context: Context): Boolean =
        context.getSystemService(KeyguardManager::class.java)?.isDeviceSecure == true

    /** Shows the system prompt; [onAuthenticated] runs only when the person unlocks it. */
    fun authenticate(activity: AppCompatActivity, title: String, subtitle: String, onAuthenticated: () -> Unit) {
        val prompt = BiometricPrompt(
            activity,
            ContextCompat.getMainExecutor(activity),
            object : BiometricPrompt.AuthenticationCallback() {
                override fun onAuthenticationSucceeded(result: BiometricPrompt.AuthenticationResult) = onAuthenticated()
            },
        )
        val info = BiometricPrompt.PromptInfo.Builder()
            .setTitle(title)
            .setSubtitle(subtitle)
            .setAllowedAuthenticators(AUTHENTICATORS)
            .build()
        // A prompt already showing refuses a second one; the dialog's Unlock button asks again.
        runCatching { prompt.authenticate(info) }
    }
}
