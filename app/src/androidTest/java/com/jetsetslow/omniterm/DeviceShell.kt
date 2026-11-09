package com.jetsetslow.omniterm

import android.os.ParcelFileDescriptor
import androidx.test.platform.app.InstrumentationRegistry

/**
 * Runs [command] as the device's shell user and returns what it printed. There is no shell in
 * between: the command is split on spaces, with no quoting, globbing or pipes.
 */
internal object DeviceShell {
    fun run(command: String): String = ParcelFileDescriptor.AutoCloseInputStream(
        InstrumentationRegistry.getInstrumentation().uiAutomation.executeShellCommand(command),
    ).bufferedReader().use { it.readText() }
}
