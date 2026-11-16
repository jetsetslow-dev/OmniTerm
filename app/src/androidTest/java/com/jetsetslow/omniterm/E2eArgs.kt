package com.jetsetslow.omniterm

import androidx.test.platform.app.InstrumentationRegistry
import java.io.File

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

    /**
     * The private fixture file [name] stands for, such as a Nebula identity: `suite` copies it into
     * the app's own files and passes only its file name. It is removed as it is read, so it never
     * outlives the run, and its content is never an argument.
     */
    fun privateFile(name: String): String {
        val fileName = require(name)
        check('/' !in fileName) { "$name names a file in the app's own files, not a path" }
        val file = File(InstrumentationRegistry.getInstrumentation().targetContext.filesDir, fileName)
        return try {
            check(file.isFile) { "$name: ${file.name} is not in the app's files; run this suite with ./scripts/test-hosts.sh suite" }
            file.readText()
        } finally {
            file.delete()
        }
    }
}
