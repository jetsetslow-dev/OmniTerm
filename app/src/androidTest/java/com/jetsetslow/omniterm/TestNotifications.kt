package com.jetsetslow.omniterm

import android.Manifest
import android.app.Notification
import android.app.NotificationManager
import android.content.pm.PackageManager
import android.os.Build
import android.os.SystemClock
import androidx.core.content.ContextCompat
import androidx.test.platform.app.InstrumentationRegistry

/** For device tests that check what the app posts: the permission, and what is showing. */
internal object TestNotifications {
    private val instrumentation get() = InstrumentationRegistry.getInstrumentation()
    private val context get() = instrumentation.targetContext

    /**
     * Lets the app post notifications on Android 13 and later, through the instrumentation shell,
     * when the test device has it denied. Returns once the grant holds.
     */
    fun allow() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return
        fun allowed() =
            ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED
        if (allowed()) return
        instrumentation.uiAutomation.executeShellCommand("pm grant ${context.packageName} ${Manifest.permission.POST_NOTIFICATIONS}").close()
        val until = SystemClock.uptimeMillis() + 5_000
        while (!allowed()) {
            check(SystemClock.uptimeMillis() < until) { "the notification permission was not granted" }
            Thread.sleep(100)
        }
    }

    /** The app's notification [id], while it shows. */
    fun posted(id: Int): Notification? =
        context.getSystemService(NotificationManager::class.java)?.activeNotifications?.firstOrNull { it.id == id }?.notification

    /** The text of the app's notification [id], while it shows. */
    fun text(id: Int): String? = posted(id)?.extras?.getCharSequence(Notification.EXTRA_TEXT)?.toString()

    /** The title of the app's notification [id], while it shows. */
    fun title(id: Int): String? = posted(id)?.extras?.getCharSequence(Notification.EXTRA_TITLE)?.toString()

    /** Takes down a notification the test made the app keep, so none is left on the device. */
    fun dismiss(id: Int) {
        context.getSystemService(NotificationManager::class.java)?.cancel(id)
    }
}
