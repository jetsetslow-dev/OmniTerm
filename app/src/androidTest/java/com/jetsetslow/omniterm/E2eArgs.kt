package com.jetsetslow.omniterm

import androidx.test.platform.app.InstrumentationRegistry

/**
 * The arguments a device suite was started with, read in one place. Start a suite with
 * `./scripts/test-hosts.sh suite <Suite> <opt-in>=yes <name>...`: a bare name is filled in from the
 * repository's fixtures (their addresses, passwords, keys and tokens), and the whole `am instrument`
 * line reaches the device on adb's standard input, so no secret is ever on a command line on the
 * computer, where `ps` shows it to every user. See that script's usage for the names it knows.
 */
internal object E2eArgs {
    private val args get() = InstrumentationRegistry.getArguments()

    /** Whether the suite was asked to run with `[name]=yes`. */
    fun on(name: String): Boolean = args.getString(name) == "yes"

    fun get(name: String): String? = args.getString(name)?.takeIf { it.isNotBlank() }

    /** [name]'s value, or a failure that says how to pass it. */
    fun require(name: String): String = requireNotNull(get(name)) {
        "$name is required: run this suite with ./scripts/test-hosts.sh suite <Suite> ... $name"
    }
}
