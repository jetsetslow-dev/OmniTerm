package com.jetsetslow.omniterm

import androidx.activity.ComponentActivity
import androidx.compose.ui.test.junit4.AndroidComposeTestRule
import androidx.test.ext.junit.rules.ActivityScenarioRule

/**
 * MainActivity's onNewIntent replaces the activity's intent, and ActivityScenario follows only an
 * activity whose intent is the one it launched: after a test sends the activity a link, a share or
 * a notification tap, the rule can no longer close it. Call this before sending one, and call what
 * it returns before any other cleanup, so the rule closes the activity even when the test failed.
 */
internal fun <A : ComponentActivity> AndroidComposeTestRule<ActivityScenarioRule<A>, A>.keepLaunchIntent(): () -> Unit {
    val launched = activity.intent
    return {
        val current = activity
        runOnUiThread { current.intent = launched }
    }
}
