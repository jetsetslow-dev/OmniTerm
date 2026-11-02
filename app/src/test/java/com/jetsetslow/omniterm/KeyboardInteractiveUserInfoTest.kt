package com.jetsetslow.omniterm

import com.jcraft.jsch.JSch
import com.jetsetslow.omniterm.data.ssh.AuthPrompt
import com.jetsetslow.omniterm.data.ssh.INTERACTIVE_AUTH_CANCELLED
import com.jetsetslow.omniterm.data.ssh.InteractiveAuth
import com.jetsetslow.omniterm.data.ssh.InteractiveAuthRequest
import com.jetsetslow.omniterm.data.ssh.KeyboardInteractiveUserInfo
import com.jetsetslow.omniterm.data.ssh.NEEDS_INTERACTIVE_AUTH
import com.jetsetslow.omniterm.data.ssh.signInFailureMessage
import kotlinx.coroutines.delay
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * A host's keyboard-interactive questions reach the user only for connections the user started.
 *
 * JSch calls [KeyboardInteractiveUserInfo.promptKeyboardInteractive] for every question it cannot
 * answer with the saved password itself: a one-time code, a forced password change. These drive
 * it the way JSch does.
 */
class KeyboardInteractiveUserInfoTest {

    private fun ask(info: KeyboardInteractiveUserInfo, vararg prompts: Pair<String, Boolean>): Array<String>? =
        info.promptKeyboardInteractive(
            "admin@nas",
            "",
            "",
            prompts.map { it.first }.toTypedArray(),
            prompts.map { it.second }.toBooleanArray(),
        )

    @Test
    fun aVerificationCodeIsAskedOfTheUserAndAnsweredInOrder() {
        var seen: InteractiveAuthRequest? = null
        val info = KeyboardInteractiveUserInfo("pw", InteractiveAuth { request ->
            seen = request
            listOf("123456", "yes")
        })

        val answers = ask(info, "Verification code: " to false, "Remember this device? " to true)

        assertArrayEquals(arrayOf("123456", "yes"), answers)
        assertEquals(listOf(AuthPrompt("Verification code: ", false), AuthPrompt("Remember this device? ", true)), seen?.prompts)
        assertEquals("admin@nas", seen?.destination)
        assertTrue(info.answeredByUser)
    }

    @Test
    fun backgroundWorkNeverAsksAndSaysWhatTheHostWants() {
        val info = KeyboardInteractiveUserInfo("pw", ask = null)

        assertNull(ask(info, "Verification code: " to false))
        assertTrue(info.neededUser)
        assertFalse(info.answeredByUser)

        val session = JSch().getSession("admin", "nas", 22).apply { userInfo = info }
        assertEquals(NEEDS_INTERACTIVE_AUTH, signInFailureMessage(session, RuntimeException("Auth cancel")))
    }

    /** As the FreeBSD lab host words it, which JSch does not answer itself. */
    @Test
    fun aPasswordPromptJschMissesGetsTheSavedPasswordOnce() {
        var asked = false
        val info = KeyboardInteractiveUserInfo("s3cret", InteractiveAuth { asked = true; listOf("x") })

        assertArrayEquals(arrayOf("s3cret"), ask(info, "Password for omni2fa@omniterm-freebsd:" to false))
        assertFalse(asked)
        assertFalse(info.answeredByUser)
    }

    @Test
    fun aRefusedSavedPasswordFailsAsBeforeInsteadOfAsking() {
        var asked = false
        val info = KeyboardInteractiveUserInfo("wrong", InteractiveAuth { asked = true; listOf("x") })

        assertArrayEquals(arrayOf("wrong"), ask(info, "Password for admin@nas:" to false))
        assertNull(ask(info, "Password for admin@nas:" to false))
        assertFalse(asked)
        assertFalse(info.neededUser)
        assertNull(ask(KeyboardInteractiveUserInfo("", InteractiveAuth { asked = true; listOf("x") }), "Password:" to false))
        assertFalse(asked)

        // JSch calls the refusal a cancel once a UserInfo is set; it still reads as a failed sign-in.
        val session = JSch().getSession("admin", "nas", 22).apply { userInfo = info }
        assertEquals("Auth fail", signInFailureMessage(session, RuntimeException("Auth cancel")))
    }

    /** JSch answers "Password:" itself, once; reaching here, the saved password was refused. */
    @Test
    fun aPasswordPromptJschAnswersIsNeverSentAgain() {
        var asked = false
        val info = KeyboardInteractiveUserInfo("wrong", InteractiveAuth { asked = true; listOf("x") })

        assertNull(ask(info, "Password: " to false))
        assertNull(ask(info, "admin@nas's password:" to false))
        // The password method asks this after a refusal; true made JSch resend it up to MaxAuthTries times.
        assertFalse(info.promptPassword("Password for admin@nas"))
        assertFalse(asked)
    }

    @Test
    fun aOneTimePasswordPromptIsAskedOfTheUser() {
        var seen: InteractiveAuthRequest? = null
        val info = KeyboardInteractiveUserInfo("s3cret", InteractiveAuth { seen = it; listOf("654321") })

        assertArrayEquals(arrayOf("654321"), ask(info, "One-time password (OATH) for `admin':" to false))
        assertEquals("One-time password (OATH) for `admin':", seen?.prompts?.single()?.text)
        assertTrue(info.answeredByUser)
    }

    @Test
    fun aForcedPasswordChangeIsAskedOfTheUser() {
        val info = KeyboardInteractiveUserInfo("old", InteractiveAuth { listOf("n3w-secret") })

        assertArrayEquals(arrayOf("n3w-secret"), ask(info, "New Password: " to false))
    }

    @Test
    fun anInformationOnlyRoundWantsNoAnswer() {
        val info = KeyboardInteractiveUserInfo("pw", ask = null)

        assertArrayEquals(emptyArray<String>(), ask(info))
        assertFalse(info.neededUser)
    }

    @Test
    fun cancellingOrTimingOutEndsTheSignIn() {
        val cancelled = KeyboardInteractiveUserInfo("pw", InteractiveAuth { null })
        assertNull(ask(cancelled, "Verification code: " to false))
        assertTrue(cancelled.cancelledByUser)
        val session = JSch().getSession("admin", "nas", 22).apply { userInfo = cancelled }
        assertEquals(INTERACTIVE_AUTH_CANCELLED, signInFailureMessage(session, RuntimeException("Auth cancel")))

        val slow = KeyboardInteractiveUserInfo("pw", InteractiveAuth { delay(5_000); listOf("1") }, timeoutMs = 50)
        assertNull(ask(slow, "Verification code: " to false))
        assertTrue(slow.cancelledByUser)

        val short = KeyboardInteractiveUserInfo("pw", InteractiveAuth { listOf("only one") })
        assertNull(ask(short, "Code: " to false, "PIN: " to false))
    }
}
