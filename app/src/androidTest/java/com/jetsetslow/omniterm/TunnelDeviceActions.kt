package com.jetsetslow.omniterm

import androidx.compose.ui.test.junit4.AndroidComposeTestRule
import androidx.test.ext.junit.rules.ActivityScenarioRule
import com.jetsetslow.omniterm.ui.AppViewModel
import com.jetsetslow.omniterm.ui.BroadcastStatus

/** Shared real SSH proof for each tunnel kind, including accepting only the disposable host key. */
internal fun AndroidComposeTestRule<ActivityScenarioRule<MainActivity>, MainActivity>.tunnelBroadcast(
    vm: AppViewModel,
    serverId: Int,
    command: String,
): Pair<BroadcastStatus, String> {
    runOnUiThread { vm.runFleetBroadcast(command, listOf(serverId)) }
    waitUntil(120_000) {
        var finished = false
        runOnUiThread {
            if (vm.pendingHostKeyApproval != null) vm.approveHostKey(true)
            finished = !vm.isBroadcastExecuting && vm.broadcastResults.any { it.serverId == serverId && it.status != BroadcastStatus.Running }
        }
        finished
    }
    return runOnIdle { vm.broadcastResults.single { it.serverId == serverId }.let { it.status to it.output } }
}
