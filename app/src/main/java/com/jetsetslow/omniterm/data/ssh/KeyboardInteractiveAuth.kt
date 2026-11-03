package com.jetsetslow.omniterm.data.ssh

import com.jcraft.jsch.Session
import com.jcraft.jsch.UIKeyboardInteractive
import com.jcraft.jsch.UserInfo
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeoutOrNull

/** One question a host asks during keyboard-interactive sign-in; [echo] false hides the answer as it is typed. */
data class AuthPrompt(val text: String, val echo: Boolean)

/** A host's keyboard-interactive questions: a one-time code, a security key's touch prompt, a new password. */
data class InteractiveAuthRequest(
    val destination: String,
    val name: String,
    val instruction: String,
    val prompts: List<AuthPrompt>,
)

/**
 * Asks the user a host's sign-in questions, for connections the user started (a terminal, Test
 * connection, browsing files). Returns the answers in order, or null when the user cancelled.
 *
 * Background work (Monitor, Containers, the status checks) passes none: it must never stop to ask,
 * so a host that wants an answer fails fast with [NEEDS_INTERACTIVE_AUTH] instead.
 */
fun interface InteractiveAuth {
    suspend fun answer(request: InteractiveAuthRequest): List<String>?

    /** Has the user's security key sign [request]; null when the user cancelled or nobody can ask. */
    suspend fun signWithSecurityKey(request: SecurityKeySignRequest): SecurityKeyAssertion? = null
}

/** What a connection says when the host asked a question only the user can answer, and nobody could be asked. */
const val NEEDS_INTERACTIVE_AUTH =
    "This host asks a sign-in question, such as a verification code. Open a terminal to it and " +
        "answer; OmniTerm's checks then use that sign-in."

/** What a connection says when the user cancelled the host's sign-in questions. */
const val INTERACTIVE_AUTH_CANCELLED = "Sign-in cancelled."

/** What a connection says when its key is on a security key, and nobody could be asked to touch it. */
const val NEEDS_SECURITY_KEY =
    "This host signs in with a security key. Open a terminal to it and touch the key; OmniTerm's " +
        "checks then use that sign-in."

/**
 * JSch's questions, routed to [ask].
 *
 * JSch answers a lone `password:` prompt with the saved password itself and calls
 * [promptKeyboardInteractive] for anything else. Without a [UserInfo] at all, every other question
 * (a TOTP code from Google Authenticator or Duo, a forced password change) failed as "Auth fail"
 * with no way to answer it.
 *
 * Some hosts word the password prompt so JSch does not recognise it (FreeBSD's PAM asks
 * "Password for user@host:"); it gets the saved password here, once. Asked again, the saved one
 * was refused, so it fails as before rather than asking: a wrong saved password still reads as one.
 * A one-time password prompt ("One-time password (OATH) for `user':") is the user's to answer.
 */
internal class KeyboardInteractiveUserInfo(
    private val password: String?,
    private val ask: InteractiveAuth?,
    private val timeoutMs: Long = PROMPT_TIMEOUT_MS,
) : UserInfo, UIKeyboardInteractive {

    /** True once the user answered a question: the session holds a sign-in nothing else can repeat. */
    @Volatile var answeredByUser = false
        private set

    /** True when the host asked something only the user can answer and nobody could be asked. */
    @Volatile var neededUser = false
        private set

    /** True when the user was asked and cancelled. */
    @Volatile var cancelledByUser = false
        private set

    /** True when [neededUser] was for a security key's touch rather than a question. */
    @Volatile var neededSecurityKey = false
        private set

    /** A security key could have signed in, but nobody was there to touch it. */
    fun securityKeyNeeded() {
        neededSecurityKey = true
        neededUser = true
    }

    fun securityKeyCancelled() {
        cancelledByUser = true
    }

    fun securityKeyUsed() {
        answeredByUser = true
    }

    private var passwordOffered = false

    override fun promptKeyboardInteractive(
        destination: String?,
        name: String?,
        instruction: String?,
        prompt: Array<String>?,
        echo: BooleanArray?,
    ): Array<String>? {
        val prompts = prompt.orEmpty().mapIndexed { i, text -> AuthPrompt(text, echo?.getOrNull(i) ?: false) }
        // An information-only round (a banner, "Touch your security key") wants no answer.
        if (prompts.isEmpty()) return emptyArray()
        val hidden = prompts.singleOrNull()?.takeIf { !it.echo }?.text
        if (hidden != null && !hidden.contains("new", ignoreCase = true)) {
            // JSch answers a prompt containing "password:" with the saved password itself, once, so
            // one that still reaches here means the saved password was refused (or there is none).
            if (hidden.contains("password:", ignoreCase = true)) return null
            if (PLAIN_PASSWORD_PROMPT.matches(hidden)) {
                if (password.isNullOrEmpty() || passwordOffered) return null
                passwordOffered = true
                return arrayOf(password)
            }
        }
        val ask = ask ?: run {
            neededUser = true
            return null
        }
        val request = InteractiveAuthRequest(destination.orEmpty(), name.orEmpty(), instruction.orEmpty(), prompts)
        val answers = runBlocking { withTimeoutOrNull(timeoutMs) { ask.answer(request) } }
        if (answers == null || answers.size != prompts.size) {
            cancelledByUser = true
            return null
        }
        answeredByUser = true
        return answers.toTypedArray()
    }

    override fun getPassphrase(): String? = null
    override fun getPassword(): String? = null

    // JSch asks this only once the saved password is used up: after the host refused it, or when
    // there is none. True made it send the same password again, up to MaxAuthTries times, each a
    // failed sign-in in the host's log.
    override fun promptPassword(message: String?): Boolean = false
    override fun promptPassphrase(message: String?): Boolean = false
    override fun promptYesNo(message: String?): Boolean = false
    override fun showMessage(message: String?) = Unit

    companion object {
        /** How long a question waits for an answer, as a new host key's approval does. */
        const val PROMPT_TIMEOUT_MS = 120_000L

        /** "Password:", "Password for user@host:", "Enter your password:": the saved password's question. */
        private val PLAIN_PASSWORD_PROMPT =
            Regex("""\s*(enter\s+)?(your\s+)?(\S+'s\s+)?password(\s+for\s+\S+)?\s*:\s*""", RegexOption.IGNORE_CASE)
    }
}

/** [error], from connecting [session], as the user should read it; [fallback] when it says nothing. */
internal fun signInFailureMessage(session: Session?, error: Throwable, fallback: String = "Connection failed"): String {
    val info = session?.userInfo as? KeyboardInteractiveUserInfo
    return when {
        info?.neededSecurityKey == true -> NEEDS_SECURITY_KEY
        info?.neededUser == true -> NEEDS_INTERACTIVE_AUTH
        info?.cancelledByUser == true -> INTERACTIVE_AUTH_CANCELLED
        // With a UserInfo set, JSch reports a refused saved password as a cancel. Nobody cancelled.
        info != null && error.message == "Auth cancel" -> "Auth fail"
        else -> error.message ?: fallback
    }
}
