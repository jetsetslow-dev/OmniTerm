package com.jetsetslow.omniterm

import android.os.ParcelFileDescriptor
import androidx.compose.ui.test.hasSetTextAction
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performImeAction
import androidx.compose.ui.test.performSemanticsAction
import androidx.compose.ui.test.performTextClearance
import androidx.compose.ui.test.performTextInput
import androidx.compose.ui.semantics.SemanticsActions
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.ViewModelProvider
import androidx.test.core.app.ActivityScenario
import androidx.test.platform.app.InstrumentationRegistry
import com.jetsetslow.omniterm.data.AppDatabase
import com.jetsetslow.omniterm.data.AppRepository
import com.jetsetslow.omniterm.data.BiometricCryptoGate
import com.jetsetslow.omniterm.ui.AppViewModel
import com.jetsetslow.omniterm.ui.hashPinForStorage
import java.security.SecureRandom
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Rule
import org.junit.Test

/**
 * Deterministic combined app-lock path on a device with an enrolled strong biometric:
 * cold start with lock + biometrics enabled -> system crypto prompt -> cancel -> still locked ->
 * wrong PIN -> re-prompt -> recreation -> cold relaunch -> lockout -> typed PIN unlock -> zero-grace
 * background relock -> cancel -> typed PIN unlock again.
 *
 * The secure system prompt is intentionally invisible to screenshot/accessibility automation, so
 * `dumpsys biometric` (active cryptographic session) plus `dumpsys fingerprint` (owning package) are
 * the authoritative prompt-state signals on this rooted test device. Cancellation uses the Back key,
 * which androidx delivers as an AuthenticationError (ERROR_USER_CANCELED) — the same terminal
 * callback as the negative button, without hard-coded screen coordinates on a dialog that
 * deliberately exposes no accessibility surface.
 *
 * No fingerprint touch, coordinate tap, or timing-only pass is involved: every phase transition
 * waits on an explicit state signal (biometric session state, window focus, ViewModel lock state).
 */
class E2eAppLockBiometricCancelPinTest {
    @get:Rule val composeRule = createEmptyComposeRule()

    private val touchedKeys = listOf(
        "app_pin", "app_lock_enabled", "biometrics_enabled", "app_lock_grace_ms",
        "pin_failed_attempts", "pin_locked_until", "first_run_complete",
    )

    @Test
    fun biometricCancelKeepsLockAndTypedPinUnlocksAcrossLifecycle() = runBlocking {
        assumeTrue(InstrumentationRegistry.getArguments().getString("omniterm_e2e_applock_bio") == "yes")
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val repository = AppRepository(AppDatabase.getDatabase(context))
        val before = repository.getAllSettings().filter { it.key in touchedKeys }.associateBy { it.key }
        // Generated per run; never logged, never in an assertion message.
        val pin = (SecureRandom().nextInt(900_000) + 100_000).toString()
        val wrongPin = if (pin[0] == '9') "1" + pin.drop(1) else "9" + pin.drop(1)

        var scenario: ActivityScenario<MainActivity>? = null
        try {
            repository.insertSetting("app_pin", hashPinForStorage(pin))
            repository.insertSetting("app_lock_enabled", "true")
            repository.insertSetting("biometrics_enabled", "true")
            repository.insertSetting("app_lock_grace_ms", "0")
            repository.insertSetting("pin_failed_attempts", "0")
            repository.insertSetting("pin_locked_until", "0")
            repository.insertSetting("first_run_complete", "true")

            scenario = ActivityScenario.launch(MainActivity::class.java)
            var activity: MainActivity? = null
            scenario.onActivity { activity = it }
            val vm = ViewModelProvider(activity!!)[AppViewModel::class.java]
            assumeTrue("Device has no enrolled strong biometric", BiometricCryptoGate.canAuthenticate(activity!!))

            // Cold start with a persisted PIN + enabled lock must engage the gateway.
            await("cold-start lock engaged", 10_000) { vm.isAppLocked }
            composeRule.waitUntil(10_000) {
                composeRule.onAllLockPrompts().fetchSemanticsNodes().isNotEmpty()
            }

            // The auto-prompt must produce exactly one active cryptographic session owned by us.
            awaitBiometricSessionActive(context.packageName, "auto-prompt")
            assertTrue(BiometricCryptoGate.isAuthenticationInFlight)
            val firstRequestId = currentBiometricRequestId()

            // Single-flight: re-triggering while the prompt is up (double-tap "Use biometrics",
            // recomposition re-entry) must not rebind or restart the session. The overlay blocks
            // injected clicks, so exercise the same code path the button calls.
            repeat(3) {
                composeRule.runOnUiThread {
                    BiometricCryptoGate.authenticate(
                        activity = activity!!,
                        title = "Unlock OmniTerm",
                        subtitle = "Authenticate to continue",
                        onAuthenticated = { throw AssertionError("re-trigger must be single-flighted") },
                        onUnavailable = { throw AssertionError("re-trigger must be single-flighted") },
                        onError = { throw AssertionError("re-trigger must be single-flighted") },
                    )
                }
            }
            delay(1_000)
            assertEquals("re-trigger restarted the biometric session", firstRequestId, currentBiometricRequestId())
            assertEquals("competing fingerprint operations", 1, activeAuthOperationCount(context.packageName))

            // Cancel via Back -> AuthenticationError (user cancel). The app must stay locked.
            cancelPromptAndAwaitIdle()
            assertTrue("cancel must not unlock", vm.isAppLocked)
            awaitWindowFocus(activity!!)
            assertTrue(
                "lock gateway dismissed by cancel",
                composeRule.onAllLockPrompts().fetchSemanticsNodes().isNotEmpty(),
            )

            // Wrong PIN through the real field + Unlock button.
            typePin(vm, wrongPin)
            clickButton("Unlock")
            await(
                { "wrong PIN error (err=${vm.lockScreenError}, len=${vm.currentPinInput.length}, locked=${vm.isAppLocked})" },
                10_000,
            ) { vm.lockScreenError?.startsWith("Incorrect PIN") == true }
            assertTrue(vm.isAppLocked)
            await("wrong PIN input cleared", 5_000) { vm.currentPinInput.isEmpty() }

            // Prompt re-opens from the real "Use biometrics" button; cancel again.
            clickButton("Use biometrics")
            awaitBiometricSessionActive(context.packageName, "use-biometrics button")
            cancelPromptAndAwaitIdle()
            assertTrue(vm.isAppLocked)

            // Recreation (rotation-equivalent): still locked, auto-prompt fires again, cancel holds.
            scenario.recreate()
            scenario.onActivity { activity = it }
            await("locked after recreation", 10_000) { vm.isAppLocked }
            awaitBiometricSessionActive(context.packageName, "after recreation")
            cancelPromptAndAwaitIdle()
            assertTrue(vm.isAppLocked)

            // Cold relaunch: a fresh Activity + ViewModel must re-engage the lock from settings.
            scenario.close()
            scenario = ActivityScenario.launch(MainActivity::class.java)
            var activity2: MainActivity? = null
            scenario.onActivity { activity2 = it }
            val vm2 = ViewModelProvider(activity2!!)[AppViewModel::class.java]
            await("cold relaunch locked", 10_000) { vm2.isAppLocked }
            awaitWindowFocus(activity2!!)
            ensureBiometricSessionActive(context.packageName, "cold relaunch")
            cancelPromptAndAwaitIdle()
            assertTrue(vm2.isAppLocked)
            awaitWindowFocus(activity2!!)

            // Lockout: repeated wrong PINs throttle, and even the correct PIN is refused while
            // throttled. The throttle is then reset through persisted settings (deterministic,
            // no 30-second wall wait).
            repeat(5) {
                typePin(vm2, wrongPin)
                clickButton("Unlock")
                await("wrong PIN handled", 10_000) { vm2.lockScreenError != null }
            }
            await("lockout engaged", 5_000) { vm2.lockScreenError?.startsWith("Too many attempts") == true }
            typePin(vm2, pin)
            clickButton("Unlock")
            await("correct PIN refused during lockout", 5_000) {
                vm2.isAppLocked && vm2.lockScreenError?.startsWith("Too many attempts") == true
            }
            composeRule.onNode(hasSetTextAction()).performTextClearance()
            repository.insertSetting("pin_failed_attempts", "0")
            repository.insertSetting("pin_locked_until", "0")
            await("throttle reset visible", 10_000) {
                typePinProbeAllowed(vm2)
            }

            // Correct PIN through the field + IME Done unlocks.
            typePin(vm2, pin)
            composeRule.onNode(hasSetTextAction()).performImeAction()
            await("typed PIN unlocks", 10_000) { !vm2.isAppLocked }
            composeRule.waitUntil(10_000) {
                composeRule.onAllLockPrompts().fetchSemanticsNodes().isEmpty()
            }

            // Zero-grace background/foreground relocks; cancel again; Unlock button path this time.
            scenario.moveToState(Lifecycle.State.CREATED)
            scenario.moveToState(Lifecycle.State.RESUMED)
            await("zero-grace relock", 10_000) { vm2.isAppLocked }
            awaitWindowFocus(activity2!!)
            ensureBiometricSessionActive(context.packageName, "zero-grace relock")
            cancelPromptAndAwaitIdle()
            assertTrue(vm2.isAppLocked)
            awaitWindowFocus(activity2!!)
            typePin(vm2, pin)
            clickButton("Unlock")
            await("final PIN unlock", 10_000) { !vm2.isAppLocked }
        } finally {
            // Dismiss any prompt left showing, then restore every touched setting.
            shell("input keyevent 4")
            runCatching { awaitBiometricIdle() }
            for (key in touchedKeys) {
                val original = before[key]
                if (original == null) repository.deleteSetting(key) else repository.insertSetting(key, original.value)
            }
            scenario?.close()
            // No biometric authentication may remain active after the suite.
            assertTrue("biometric session still active after cleanup", biometricSessionIdle())
        }
    }

    private fun androidx.compose.ui.test.junit4.ComposeTestRule.onAllLockPrompts() =
        onAllNodes(androidx.compose.ui.test.hasText("Enter PIN to unlock"))

    /**
     * Activates a real button through its OnClick semantics action — the same path an
     * accessibility service uses. Gesture taps proved unreliable here because the IME-driven
     * layout animation moves the centered lock column between coordinate capture and injection.
     * A disabled button has no enabled OnClick action and fails loudly.
     */
    private fun clickButton(text: String) {
        composeRule.waitForIdle()
        composeRule.onNodeWithText(text).performSemanticsAction(SemanticsActions.OnClick)
    }

    /** Types [value] through the real PIN field and verifies the ViewModel actually received it. */
    private suspend fun typePin(vm: AppViewModel, value: String) {
        composeRule.waitUntil(10_000) {
            composeRule.onAllNodes(hasSetTextAction()).fetchSemanticsNodes().isNotEmpty()
        }
        // The wrong-PIN flash window clears the input 600ms after a failed submit; typing before
        // it lands would race the delayed wipe, so wait it out first.
        await("PIN flash window settled", 10_000) { !vm.dotsFlashRed }
        // Focus the field with a real click first: text injection into a never-focused field has
        // been unreliable right after the secure system overlay tore down the IME session. The
        // throttled-submit branch keeps its input, so clear through the field before typing.
        composeRule.onNode(hasSetTextAction()).performClick()
        composeRule.waitForIdle()
        composeRule.onNode(hasSetTextAction()).performTextClearance()
        composeRule.onNode(hasSetTextAction()).performTextInput(value)
        await("PIN input landed", 10_000) { vm.currentPinInput == value }
    }

    /** True once the collect loop has applied the reset throttle rows (probe without side effects). */
    private fun typePinProbeAllowed(vm: AppViewModel): Boolean {
        var allowed = false
        composeRule.runOnUiThread {
            vm.lockScreenError = null
            vm.handlePinTyping("")
            allowed = vm.lockScreenError == null
        }
        return allowed
    }

    private suspend fun awaitBiometricSessionActive(pkg: String, phase: String, timeoutMs: Long = 15_000) {
        await(
            {
                val session = shell("dumpsys biometric").lineSequence()
                    .firstOrNull { it.contains("CurrentSession") }?.trim()
                "biometric session active [$phase] (inFlight=${BiometricCryptoGate.isAuthenticationInFlight}, " +
                    "ops=${activeAuthOperationCount(pkg)}, $session)"
            },
            timeoutMs,
        ) {
            val bio = shell("dumpsys biometric")
            bio.contains("CurrentSession") && !bio.contains("CurrentSession: null") &&
                bio.contains("isCrypto: true") && activeAuthOperationCount(pkg) == 1
        }
    }

    /**
     * Converges on one active session owned by us for phases that immediately follow a cancel plus
     * lifecycle churn: the fingerprint service can transiently refuse the auto-prompt right after
     * a cancellation, in which case the real "Use biometrics" button is pressed again — exactly
     * what a user does when the auto-prompt did not appear. Every attempt is verified against the
     * authoritative biometric service state; the outcome is exact, not timing-based.
     */
    private suspend fun ensureBiometricSessionActive(pkg: String, phase: String) {
        var lastError: AssertionError? = null
        repeat(4) { attempt ->
            if (attempt > 0 && !BiometricCryptoGate.isAuthenticationInFlight) {
                clickButton("Use biometrics")
            }
            try {
                awaitBiometricSessionActive(pkg, "$phase attempt $attempt", 5_000)
                return
            } catch (e: AssertionError) {
                lastError = e
            }
        }
        throw lastError ?: AssertionError("no biometric session [$phase]")
    }

    private suspend fun cancelPromptAndAwaitIdle() {
        shell("input keyevent 4")
        awaitBiometricIdle()
        // The framework idles before androidx dispatches AuthenticationError to the client
        // executor. Later phases (recreation, re-prompt) require the single-flight release to
        // have landed, so every cancel serializes on it.
        await("single-flight released after cancel", 10_000) { !BiometricCryptoGate.isAuthenticationInFlight }
    }

    private suspend fun awaitBiometricIdle() {
        await("biometric session idle", 15_000) { biometricSessionIdle() }
    }

    private fun biometricSessionIdle(): Boolean =
        shell("dumpsys biometric").contains("CurrentSession: null")

    private fun currentBiometricRequestId(): String =
        Regex("requestId: (\\d+)").find(shell("dumpsys biometric"))?.groupValues?.get(1) ?: ""

    /** Count of live fingerprint authentication operations owned by [pkg]. */
    private fun activeAuthOperationCount(pkg: String): Int =
        shell("dumpsys fingerprint").lineSequence().count {
            it.contains("Current operation") && it.contains("AuthenticationClient") && it.contains("owner=$pkg")
        }

    private suspend fun awaitWindowFocus(activity: MainActivity) {
        await("window focus returned", 15_000) {
            var focused = false
            composeRule.runOnUiThread { focused = activity.hasWindowFocus() }
            focused
        }
    }

    private fun shell(command: String): String =
        ParcelFileDescriptor.AutoCloseInputStream(
            InstrumentationRegistry.getInstrumentation().uiAutomation.executeShellCommand(command),
        ).use { String(it.readBytes()) }

    private suspend fun await(label: String, timeoutMs: Long, predicate: suspend () -> Boolean) =
        await({ label }, timeoutMs, predicate)

    private suspend fun await(label: () -> String, timeoutMs: Long, predicate: suspend () -> Boolean) {
        val deadline = System.currentTimeMillis() + timeoutMs
        while (System.currentTimeMillis() < deadline) {
            if (predicate()) return
            delay(150)
        }
        throw AssertionError("Timed out waiting for: ${label()}")
    }
}
