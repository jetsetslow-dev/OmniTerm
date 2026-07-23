package com.jetsetslow.omniterm

import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.lifecycle.ViewModelProvider
import com.jetsetslow.omniterm.ui.AppViewModel
import com.jetsetslow.omniterm.ui.Screen
import com.jetsetslow.omniterm.ui.SftpTransferItem
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test

class TransferProgressUiTest {
    @get:Rule
    val composeTestRule = createAndroidComposeRule<MainActivity>()

    @Test
    fun progressMutationRefreshesBarAndTabRemainsInteractive() {
        val viewModel = ViewModelProvider(composeTestRule.activity)[AppViewModel::class.java]
        val item = SftpTransferItem(
            id = "progress-test",
            serverId = 7,
            serverName = "files-host",
            direction = "Upload",
            name = "archive.bin",
            remotePath = "/tmp/archive.bin",
            bytesTransferred = 512L * 1024,
            totalBytes = 1024L * 1024,
            speedKbps = 256f,
        )
        composeTestRule.runOnUiThread {
            viewModel.sftpTransfers.clear()
            viewModel.sftpTransfers.add(item)
            viewModel.activeSftpTab = 3
            viewModel.navigateTo(Screen.SFTP)
        }

        composeTestRule.onNodeWithText("Transferring 1 file").assertIsDisplayed()
        composeTestRule.onNodeWithText("512.0 KB of 1.0 MB", substring = true).assertIsDisplayed()

        composeTestRule.runOnUiThread {
            viewModel.sftpTransfers[0] = item.copy(bytesTransferred = 768L * 1024, speedKbps = 384f)
        }
        composeTestRule.onNodeWithText("768.0 KB of 1.0 MB", substring = true).assertIsDisplayed()

        composeTestRule.onNodeWithText("Bookmarks").performClick()
        composeTestRule.runOnIdle { assertEquals(0, viewModel.activeSftpTab) }
        composeTestRule.runOnUiThread { viewModel.sftpTransfers.clear() }
    }
}
