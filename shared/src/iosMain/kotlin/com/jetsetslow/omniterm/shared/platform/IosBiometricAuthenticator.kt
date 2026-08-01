@file:OptIn(kotlinx.cinterop.ExperimentalForeignApi::class)

package com.jetsetslow.omniterm.shared.platform

import kotlinx.coroutines.suspendCancellableCoroutine
import platform.LocalAuthentication.LAContext
import platform.LocalAuthentication.LAPolicyDeviceOwnerAuthentication
import platform.LocalAuthentication.LAPolicyDeviceOwnerAuthenticationWithBiometrics
import kotlin.coroutines.resume

class IosBiometricAuthenticator(
    private val allowDevicePasscodeFallback: Boolean = false,
) : BiometricAuthenticator {
    private var activeContext: LAContext? = null

    override suspend fun authenticate(reason: AuthenticationReason): CapabilityResult<Unit> =
        suspendCancellableCoroutine { continuation ->
            val context = LAContext()
            val policy = if (allowDevicePasscodeFallback) {
                LAPolicyDeviceOwnerAuthentication
            } else {
                LAPolicyDeviceOwnerAuthenticationWithBiometrics
            }
            activeContext?.invalidate()
            activeContext = context
            continuation.invokeOnCancellation { context.invalidate() }
            if (!context.canEvaluatePolicy(policy, error = null)) {
                activeContext = null
                continuation.resume(CapabilityResult.Unsupported("Device authentication is unavailable"))
                return@suspendCancellableCoroutine
            }
            val prompt = when (reason) {
                AuthenticationReason.UnlockApp -> "Unlock OmniTerm"
                AuthenticationReason.RevealSecret -> "Reveal the protected credential"
                AuthenticationReason.ConfirmSensitiveAction -> "Confirm this sensitive action"
            }
            context.evaluatePolicy(policy, localizedReason = prompt) { success, _ ->
                if (!continuation.isActive) return@evaluatePolicy
                activeContext = null
                continuation.resume(
                    if (success) CapabilityResult.Available(Unit)
                    else CapabilityResult.Failed(PlatformError.AuthenticationFailed),
                )
            }
        }

    override fun cancel() {
        activeContext?.invalidate()
        activeContext = null
    }
}
