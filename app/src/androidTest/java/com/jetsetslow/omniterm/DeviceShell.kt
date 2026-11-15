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

/**
 * Takes the phone off every network it is on, Wi-Fi and mobile data, as losing signal does, and
 * on [close] turns back on what was on. A host reached through adb's reverse ports (127.0.0.1)
 * stays reachable: a suite that needs a host to go away saves one at `network_host`, the address
 * the phone's own network reaches the fixtures at. USB adb keeps working; adb over Wi-Fi does not.
 */
internal class PhoneOffline : AutoCloseable {
    private val wifiWasOn = DeviceShell.run("settings get global wifi_on").trim() != "0"
    private val dataWasOn = DeviceShell.run("settings get global mobile_data").trim() != "0"

    init {
        DeviceShell.run("svc wifi disable")
        DeviceShell.run("svc data disable")
    }

    override fun close() {
        if (wifiWasOn) DeviceShell.run("svc wifi enable")
        if (dataWasOn) DeviceShell.run("svc data enable")
    }
}
