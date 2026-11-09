package com.jetsetslow.omniterm.data

import android.os.Bundle
import android.util.Base64
import java.security.MessageDigest
import java.security.SecureRandom
import java.util.Locale

/**
 * Automation: other apps (Tasker, Locale-style plug-in hosts, anything that can send a broadcast)
 * run one saved script on chosen hosts. Each grant is a token the user made in OmniTerm for one
 * script and its hosts; the token is shown once, only its SHA-256 is kept, and the grant can be
 * revoked. Nothing runs while the Automation switch is off, and a script runs only when it could
 * be a script check too (see [UnattendedScripts]).
 *
 * Credit: the Tasker plug-in protocol is from Tasker's plug-in pages (tasker.joaoapps.com/plugins.html)
 * and the Locale plug-in spec (twofortyfouram/android-monorepo, Apache-2.0); the protocol's names
 * are implemented from those pages, no code is copied. The Nov 7 review of competing apps asked for
 * Tasker actions (see the README's acknowledgements).
 */
object Automation {
    /** The setting that turns automation on; off unless the user turns it on. */
    const val SETTING_ENABLED = "automation_enabled"

    /** A plain broadcast that runs a grant's script: `am broadcast` or Tasker's Send Intent. */
    const val ACTION_RUN = "com.jetsetslow.omniterm.action.RUN_SCRIPT"
    const val EXTRA_TOKEN = "com.jetsetslow.omniterm.extra.TOKEN"
    /** With [EXTRA_REPLY_ACTION]: where the result goes, as a broadcast to that package only. */
    const val EXTRA_REPLY_PACKAGE = "com.jetsetslow.omniterm.extra.REPLY_PACKAGE"
    const val EXTRA_REPLY_ACTION = "com.jetsetslow.omniterm.extra.REPLY_ACTION"
    /** Any text the caller wants back in the reply, to match it to its request. */
    const val EXTRA_REQUEST_ID = "com.jetsetslow.omniterm.extra.REQUEST_ID"

    // The reply's extras.
    const val EXTRA_EXIT = "com.jetsetslow.omniterm.extra.EXIT"
    const val EXTRA_OUTPUT = "com.jetsetslow.omniterm.extra.OUTPUT"
    const val EXTRA_FAILED_HOSTS = "com.jetsetslow.omniterm.extra.FAILED_HOSTS"
    const val EXTRA_ERROR = "com.jetsetslow.omniterm.extra.ERROR"

    /** A run stops waiting for its hosts after this, so it ends inside Android's limit for a background job. */
    const val RUN_TIMEOUT_MS = 9 * 60_000L
    /** How long a Tasker task waits for the result: the run's limit plus time to start and reply. */
    const val TASKER_TIMEOUT_MS = 10 * 60_000
    /** The exit status a run reports for a host it could not reach or sign in to, as ssh(1) does. */
    const val UNREACHABLE = 255
    /** The exit status for a host that had not finished in time, as timeout(1) does. */
    const val TIMED_OUT = 124
    /** The exit status for a host whose shell cannot be given a `{{value}}`'s default safely. */
    const val UNSAFE_VALUE = 2
    /** The most of the hosts' combined output a reply carries; the end is kept. */
    const val REPLY_OUTPUT_CHARS = 32_000
    /** Hosts run at once. */
    const val PARALLEL_HOSTS = 8

    private const val TOKEN_PREFIX = "omt_"
    private const val TOKEN_BYTES = 16

    /** A new token: [TOKEN_PREFIX] and 128 random bits, URL-safe so it survives being typed into another app. */
    fun newToken(random: SecureRandom = SecureRandom()): String {
        val bytes = ByteArray(TOKEN_BYTES).also(random::nextBytes)
        return TOKEN_PREFIX + Base64.encodeToString(bytes, Base64.URL_SAFE or Base64.NO_PADDING or Base64.NO_WRAP)
    }

    /** Whether [text] has a token's shape; anything else is refused before a database read. */
    fun looksLikeToken(text: String?): Boolean =
        text != null && text.length == TOKEN_PREFIX.length + 22 && text.startsWith(TOKEN_PREFIX) &&
            text.drop(TOKEN_PREFIX.length).all { it.isLetterOrDigit() && it.code < 128 || it == '-' || it == '_' }

    /** What is stored for [token]: its SHA-256, lower-case hex. */
    fun hash(token: String): String =
        MessageDigest.getInstance("SHA-256").digest(token.toByteArray(Charsets.UTF_8))
            .joinToString("") { "%02x".format(Locale.ROOT, it) }

    fun joinServerIds(ids: Collection<Int>): String = ids.distinct().sorted().joinToString(",")

    fun parseServerIds(csv: String): List<Int> =
        csv.split(',').mapNotNull { it.trim().toIntOrNull()?.takeIf { id -> id > 0 } }.distinct()

    /**
     * Whether [script] says it is not for a host with [os] (as [RemoteCommands.normaliseOs] names
     * it): Fleet's own skip, from the one fact a background run has, the host's OS.
     */
    fun skipsOs(script: QuickScriptEntity, os: String): Boolean {
        val target = script.targetOs.trim()
        if (target.isEmpty() || target.equals("Any", ignoreCase = true)) return false
        if (os.isBlank() || os.equals("Unknown", ignoreCase = true)) return false
        return !os.equals(target, ignoreCase = true)
    }

    /** One host's part of a run. [exit] is null for a host the script skipped. */
    data class HostResult(
        val serverId: Int,
        val name: String,
        val exit: Int?,
        val output: String,
        val note: String? = null,
    )

    /** A finished run, or one refused before it started ([error] set, no hosts). */
    data class RunResult(val hosts: List<HostResult>, val error: String? = null) {
        val ran: List<HostResult> get() = hosts.filter { it.exit != null }
        val failed: List<HostResult> get() = ran.filter { it.exit != 0 }
        /** It ran somewhere and every host that ran succeeded. */
        val succeeded: Boolean get() = error == null && ran.isNotEmpty() && failed.isEmpty()
        /** 0 on success; else the first failed host's status, or 1 when nothing ran. */
        val exit: Int get() = when {
            succeeded -> 0
            else -> failed.firstOrNull()?.exit ?: 1
        }
        /**
         * Why it failed, for Tasker's %errmsg and the reply's error: each failed host's note, or each
         * skipped host's when none ran. Null on success.
         */
        val errorMessage: String? get() = when {
            error != null -> error
            succeeded -> null
            else -> failed.ifEmpty { hosts }.joinToString("; ") { "${it.name}: ${it.note.orEmpty()}" }
        }

        /** Each host's output under its name, as Fleet's shared report reads, its end kept to [REPLY_OUTPUT_CHARS]. */
        fun combinedOutput(): String {
            val text = if (hosts.size == 1) hosts.single().output.trimEnd()
            else hosts.joinToString("\n\n") { h ->
                "== ${h.name} ==\n" + h.output.trimEnd().ifEmpty { h.note.orEmpty() }
            }
            return if (text.length > REPLY_OUTPUT_CHARS) text.takeLast(REPLY_OUTPUT_CHARS) else text
        }
    }

    /** The Locale and Tasker plug-in protocol, from their published pages. */
    object Plugin {
        const val ACTION_EDIT_SETTING = "com.twofortyfouram.locale.intent.action.EDIT_SETTING"
        const val ACTION_FIRE_SETTING = "com.twofortyfouram.locale.intent.action.FIRE_SETTING"
        const val EXTRA_BUNDLE = "com.twofortyfouram.locale.intent.extra.BUNDLE"
        const val EXTRA_BLURB = "com.twofortyfouram.locale.intent.extra.BLURB"

        private const val TASKER = "net.dinglisch.android.tasker"
        const val EXTRA_COMPLETION_INTENT = "$TASKER.extras.COMPLETION_INTENT"
        const val EXTRA_RESULT_CODE = "$TASKER.extras.RESULT_CODE"
        const val EXTRA_VARIABLES = "$TASKER.extras.VARIABLES"
        const val EXTRA_REQUESTED_TIMEOUT = "$TASKER.extras.REQUESTED_TIMEOUT"
        const val EXTRA_HOST_CAPABILITIES = "$TASKER.extras.HOST_CAPABILITIES"
        const val EXTRA_RELEVANT_VARIABLES = "$TASKER.RELEVANT_VARIABLES"
        /** The host waits for [EXTRA_COMPLETION_INTENT]. */
        const val CAPABILITY_SYNCHRONOUS = 32
        const val CAPABILITY_RELEVANT_VARIABLES = 16

        /** The fire broadcast's result code meaning "the result follows on the completion intent". */
        const val RESULT_PENDING = 3
        const val RESULT_OK = -1
        const val RESULT_FAILED = 2

        // Ours, inside the plug-in bundle.
        const val BUNDLE_TOKEN = "com.jetsetslow.omniterm.bundle.TOKEN"
        const val BUNDLE_VERSION = "com.jetsetslow.omniterm.bundle.VERSION"
        const val BUNDLE_VERSION_CURRENT = 1

        const val VAR_OUTPUT = "%output"
        const val VAR_EXIT = "%exit"
        const val VAR_FAILED_HOSTS = "%failed_hosts"
        const val VAR_ERRMSG = "%errmsg"

        /** The token a plug-in bundle carries, or null when it is not one of ours. */
        fun tokenFrom(bundle: Bundle?): String? =
            runCatching { bundle?.getString(BUNDLE_TOKEN) }.getOrNull()?.takeIf(::looksLikeToken)

        fun bundleFor(token: String): Bundle = Bundle().apply {
            putString(BUNDLE_TOKEN, token)
            putInt(BUNDLE_VERSION, BUNDLE_VERSION_CURRENT)
        }

        /** Tasker's variables for [result]; %errmsg only on failure, as Tasker expects. */
        fun variables(result: RunResult): Bundle = Bundle().apply {
            putString(VAR_OUTPUT, result.combinedOutput())
            putString(VAR_EXIT, result.exit.toString())
            putString(VAR_FAILED_HOSTS, result.failed.joinToString(",") { it.name })
            result.errorMessage?.takeUnless { result.succeeded }?.let { putString(VAR_ERRMSG, it) }
        }
    }
}
