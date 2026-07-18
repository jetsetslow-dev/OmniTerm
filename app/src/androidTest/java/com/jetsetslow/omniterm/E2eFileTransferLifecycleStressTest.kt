package com.jetsetslow.omniterm

import android.net.Uri
import android.os.ParcelFileDescriptor
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.ViewModelProvider
import androidx.test.platform.app.InstrumentationRegistry
import com.jetsetslow.omniterm.data.AppDatabase
import com.jetsetslow.omniterm.data.AppRepository
import com.jetsetslow.omniterm.data.NetworkShareEntity
import com.jetsetslow.omniterm.data.SftpFile
import com.jetsetslow.omniterm.data.shares.RemoteFsClient
import com.jetsetslow.omniterm.data.shares.ShareClients
import com.jetsetslow.omniterm.ui.AppViewModel
import com.jetsetslow.omniterm.ui.Screen
import com.jetsetslow.omniterm.ui.SftpTransferStatus
import com.jetsetslow.omniterm.ui.TRANSFER_CANCELLED_MESSAGE
import java.io.ByteArrayInputStream
import java.io.OutputStream
import java.security.MessageDigest
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Rule
import org.junit.Test

/** Destructive only inside unique directories on the disposable lab. */
class E2eFileTransferLifecycleStressTest {
    @get:Rule
    val composeRule = createAndroidComposeRule<MainActivity>()

    @Test
    fun transfersCancelRecoverRetryAndCrossEndpointsWithoutPartialData() = runBlocking {
        assumeTrue(InstrumentationRegistry.getArguments().getString("omniterm_e2e_transfer_lifecycle") == "yes")
        ensureDeviceAwake()
        composeRule.activityRule.scenario.moveToState(Lifecycle.State.RESUMED)
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        val vm = ViewModelProvider(composeRule.activity)[AppViewModel::class.java]
        val repository = AppRepository(AppDatabase.getDatabase(context))
        val shares = repository.getAllNetworkShares().filter { it.name.startsWith("E2E ") }.sortedBy { it.protocol }
        assertEquals(setOf("FTP", "SMB", "SFTP", "WEBDAV"), shares.map { it.protocol.uppercase() }.toSet())
        val authority = "${context.packageName}.slowtransfer"
        val runId = System.currentTimeMillis().toString(36)
        val roots = linkedMapOf<NetworkShareEntity, String>()
        SlowTransferContentProvider.reset()

        try {
            // Isolate every mutation so an interrupted assertion can be cleaned in reverse later.
            for (share in shares) {
                client(share).use { fs ->
                    val base = ShareClients.startPath(share, fs).ifBlank { "/" }
                    val root = join(base, "omniterm-e2e-transfer-$runId-${share.protocol.lowercase()}")
                    fs.mkdir(root)
                    roots[share] = root
                }
            }
            composeRule.runOnUiThread {
                vm.navigateTo(Screen.SFTP)
                vm.activeSftpTab = 2
            }

            // Every protocol must abort a live upload promptly and remove only its hidden staging
            // file; no user-visible short destination may remain.
            for ((share, root) in roots) {
                openShare(vm, share, root)
                vm.sftpTransfers.clear()
                val name = "cancel-${share.protocol.lowercase()}.bin"
                val uri = slowUri(authority, "upload", name, 12L * MIB, delayMs = 4)
                vm.shareUploadMany(listOf(uri), context)
                val row = awaitRunning(vm, name)
                await("${share.protocol} upload progress", 20_000) {
                    vm.sftpTransfers.find { it.id == row.id }?.bytesTransferred ?: 0L >= 256 * 1024
                }
                vm.cancelSftpTransfer(row.id)
                await("${share.protocol} bounded cancel", 12_000) {
                    vm.sftpTransfers.find { it.id == row.id }?.status == SftpTransferStatus.Failure
                }
                assertEquals(TRANSFER_CANCELLED_MESSAGE, vm.sftpTransfers.find { it.id == row.id }?.message)
                client(share).use { fs ->
                    val names = fs.list(root).map { it.name }
                    assertFalse("${share.protocol} left final file", name in names)
                    assertFalse("${share.protocol} left staging file: $names", names.any { ".omniterm-part-" in it })
                }
            }

            val sftp = requireNotNull(roots.keys.find { it.protocol.equals("SFTP", true) })
            val sftpRoot = requireNotNull(roots[sftp])
            openShare(vm, sftp, sftpRoot)

            // A larger upload remains owned by the retained ViewModel across Home-equivalent
            // lifecycle movement and Activity recreation, then commits at the exact expected size.
            vm.sftpTransfers.clear()
            val largeName = "large-recreate.bin"
            val largeBytes = 32L * MIB
            val largeUri = slowUri(authority, "upload", largeName, largeBytes, delayMs = 5)
            vm.shareUploadMany(listOf(largeUri), context)
            val largeRow = awaitRunning(vm, largeName)
            await("large upload starts", 20_000) {
                vm.sftpTransfers.find { it.id == largeRow.id }?.bytesTransferred ?: 0L >= 512 * 1024
            }
            composeRule.activityRule.scenario.moveToState(Lifecycle.State.CREATED)
            delay(500)
            ensureDeviceAwake()
            composeRule.activityRule.scenario.moveToState(Lifecycle.State.RESUMED)
            composeRule.activityRule.scenario.recreate()
            assertSame(vm, ViewModelProvider(composeRule.activity)[AppViewModel::class.java])
            await("large upload after recreation", 60_000) {
                vm.sftpTransfers.find { it.id == largeRow.id }?.status == SftpTransferStatus.Success
            }
            client(sftp).use { fs -> assertEquals(largeBytes, fs.list(sftpRoot).single { it.name == largeName }.size) }

            // A blocked destination is cancellable too, and the SAF document is explicitly deleted
            // rather than being left as a plausible-looking partial download.
            val downloadUri = slowUri(authority, "download", "cancel-download.bin", largeBytes, delayMs = 6)
            vm.shareDownload(largeName, downloadUri, context)
            val downloadRow = awaitRunning(vm, "cancel-download.bin", direction = "Download", fallbackName = largeName)
            await("download progress", 20_000) {
                vm.sftpTransfers.find { it.id == downloadRow.id }?.bytesTransferred ?: 0L >= 256 * 1024
            }
            vm.cancelSftpTransfer(downloadRow.id)
            await("download cancellation", 12_000) {
                vm.sftpTransfers.find { it.id == downloadRow.id }?.status == SftpTransferStatus.Failure
            }
            assertTrue("partial SAF download was not deleted", downloadUri.toString() in SlowTransferContentProvider.deletedUris)

            // A provider that ends halfway must fail before commit. Retry then reopens the source,
            // and must target the original FTP path even after the UI has moved to another share.
            val ftp = requireNotNull(roots.keys.find { it.protocol.equals("FTP", true) })
            val ftpRoot = requireNotNull(roots[ftp])
            val smb = requireNotNull(roots.keys.find { it.protocol.equals("SMB", true) })
            openShare(vm, ftp, ftpRoot)
            val retryName = "retry-exact-endpoint.bin"
            val retryUri = slowUri(authority, "upload", retryName, 6L * MIB, delayMs = 1, failOnce = true)
            vm.shareUploadMany(listOf(retryUri), context)
            val failed = awaitRunning(vm, retryName)
            await("short source rejection", 30_000) {
                vm.sftpTransfers.find { it.id == failed.id }?.let { it.status == SftpTransferStatus.Failure && it.retryable } == true
            }
            client(ftp).use { fs -> assertFalse(fs.list(ftpRoot).any { it.name == retryName }) }
            openShare(vm, smb, requireNotNull(roots[smb]))
            vm.retrySftpTransfer(requireNotNull(vm.sftpTransfers.find { it.id == failed.id }))
            await("exact endpoint retry", 45_000) {
                vm.sftpTransfers.any { it.name == retryName && it.id != failed.id && it.status == SftpTransferStatus.Success }
            }
            client(ftp).use { fs -> assertEquals(6L * MIB, fs.list(ftpRoot).single { it.name == retryName }.size) }
            client(smb).use { fs -> assertFalse(fs.list(requireNotNull(roots[smb])).any { it.name == retryName }) }

            // Real Wi-Fi loss during an active upload, followed by a user cancellation, must return
            // control within the same bound even if a protocol socket would otherwise wait longer.
            openShare(vm, ftp, ftpRoot)
            val wifiName = "wifi-loss.bin"
            val wifiUri = slowUri(authority, "upload", wifiName, 64L * MIB, delayMs = 5)
            vm.shareUploadMany(listOf(wifiUri), context)
            val wifiRow = awaitRunning(vm, wifiName)
            await("Wi-Fi upload progress", 20_000) {
                vm.sftpTransfers.find { it.id == wifiRow.id }?.bytesTransferred ?: 0L >= 512 * 1024
            }
            shell("svc wifi disable")
            delay(2_000)
            vm.cancelSftpTransfer(wifiRow.id)
            shell("svc wifi enable")
            await("Wi-Fi-loss cancellation", 15_000) {
                vm.sftpTransfers.find { it.id == wifiRow.id }?.status == SftpTransferStatus.Failure
            }
            await("Wi-Fi reconnect", 30_000) { canList(ftp, ftpRoot) }
            client(ftp).use { fs ->
                val names = fs.list(ftpRoot).map { it.name }
                assertFalse(wifiName in names)
                assertFalse(names.any { ".omniterm-part-" in it })
            }

            // Cross-protocol overwrite confirmation is exercised through the visible UI. Copy FTP
            // -> SMB replaces the old bytes only after a complete staged stream; cut SMB -> WebDAV
            // removes the source only after the destination is committed.
            val crossName = "cross-overwrite.bin"
            val expected = ByteArray(2 * MIB.toInt()) { index -> ((index * 13 + 7) and 0xff).toByte() }
            client(ftp).use { it.uploadStream(join(ftpRoot, crossName), ByteArrayInputStream(expected), expected.size.toLong()) }
            client(smb).use { it.uploadStream(join(requireNotNull(roots[smb]), crossName), ByteArrayInputStream(byteArrayOf(1, 2, 3)), 3) }
            openShare(vm, ftp, ftpRoot)
            vm.shareClipFile(requireNotNull(vm.shareEntries.find { it.name == crossName }), move = false)
            openShare(vm, smb, requireNotNull(roots[smb]))
            composeRule.onNodeWithText("Paste here").performClick()
            composeRule.onNodeWithText("Overwrite existing item(s)?").assertExists()
            composeRule.onNodeWithText("Overwrite").performClick()
            await("FTP to SMB overwrite", 45_000) { !vm.crossPasteRunning && vm.crossClipboard.isEmpty() }
            assertDigest(expected, smb, requireNotNull(roots[smb]), crossName)

            val webDav = requireNotNull(roots.keys.find { it.protocol.equals("WEBDAV", true) })
            openShare(vm, smb, requireNotNull(roots[smb]))
            vm.shareClipFile(requireNotNull(vm.shareEntries.find { it.name == crossName }), move = true)
            openShare(vm, webDav, requireNotNull(roots[webDav]))
            vm.pasteIntoShare()
            await("SMB to WebDAV move", 45_000) { !vm.crossPasteRunning && vm.crossClipboard.isEmpty() }
            client(smb).use { fs -> assertFalse(fs.list(requireNotNull(roots[smb])).any { it.name == crossName }) }
            assertDigest(expected, webDav, requireNotNull(roots[webDav]), crossName)

            // Dual-pane navigation is independent: pane B can traverse a nested SFTP path without
            // changing pane A's selected host or directory.
            val host = requireNotNull(vm.servers.value.find { it.name == "E2E Foreground Demo" })
            vm.selectedServerId = host.id
            vm.loadSftp("/home/${host.username}/omniterm-e2e")
            await("primary SFTP pane", 25_000) { !vm.sftpLoading && vm.sftpError.isNullOrBlank() }
            val primaryPath = vm.sftpPath
            if (!vm.dualPaneEnabled) vm.toggleDualPane()
            vm.paneBSelectServer(host.id)
            vm.loadPaneB("/home/${host.username}/omniterm-e2e")
            await("secondary SFTP pane", 25_000) { !vm.paneBLoading && vm.paneBError.isNullOrBlank() }
            val nested = vm.paneBEntries.firstOrNull { it.isDirectory }
            if (nested != null) {
                vm.paneBNavigateInto(nested.name)
                await("secondary nested navigation", 25_000) { !vm.paneBLoading && vm.paneBPath.endsWith("/${nested.name}") }
                assertEquals(primaryPath, vm.sftpPath)
                vm.paneBNavigateUp()
                await("secondary navigate up", 25_000) { !vm.paneBLoading && vm.paneBPath == primaryPath }
            }
        } finally {
            shell("svc wifi enable")
            composeRule.runOnUiThread {
                vm.cancelAllRunningTransfers()
                vm.closeShareBrowser()
            }
            for ((share, root) in roots.entries.reversed()) {
                runCatching { client(share).use { deleteTree(it, root) } }
            }
        }
    }

    private suspend fun openShare(vm: AppViewModel, share: NetworkShareEntity, root: String) {
        composeRule.runOnUiThread { vm.openShareBrowser(share, root) }
        await("${share.protocol} open $root", 30_000) {
            vm.browsingShare?.id == share.id && vm.sharePath == root && !vm.shareLoading && vm.shareError.isNullOrBlank()
        }
    }

    private suspend fun awaitRunning(vm: AppViewModel, name: String, direction: String = "Upload", fallbackName: String? = null) =
        awaitValue("$direction $name row", 15_000) {
            vm.sftpTransfers.firstOrNull {
                it.status == SftpTransferStatus.InProgress && it.direction == direction &&
                    (it.name == name || (fallbackName != null && it.name == fallbackName))
            }
        }

    private fun slowUri(authority: String, kind: String, name: String, bytes: Long, delayMs: Int, failOnce: Boolean = false): Uri =
        Uri.Builder().scheme("content").authority(authority).appendPath(kind).appendPath(name)
            .appendQueryParameter("bytes", bytes.toString())
            .appendQueryParameter("delay_ms", delayMs.toString())
            .apply { if (failOnce) appendQueryParameter("fail_once", "true") }
            .build()

    private fun client(share: NetworkShareEntity): RemoteFsClient = ShareClients.forShare(share, share.username, share.password)

    private suspend fun canList(share: NetworkShareEntity, root: String): Boolean =
        runCatching { client(share).use { it.list(root) }; true }.getOrDefault(false)

    private suspend fun assertDigest(expected: ByteArray, share: NetworkShareEntity, root: String, name: String) {
        val digest = MessageDigest.getInstance("SHA-256")
        client(share).use { fs ->
            val bytes = fs.downloadTo(join(root, name), object : OutputStream() {
                override fun write(value: Int) { digest.update(value.toByte()) }
                override fun write(buffer: ByteArray, offset: Int, length: Int) { digest.update(buffer, offset, length) }
            })
            assertEquals(expected.size.toLong(), bytes)
        }
        assertArrayEquals(MessageDigest.getInstance("SHA-256").digest(expected), digest.digest())
    }

    private suspend fun deleteTree(fs: RemoteFsClient, path: String) {
        fs.list(path).forEach { entry ->
            val child = join(path, entry.name)
            if (entry.isDirectory) deleteTree(fs, child) else fs.delete(child, false)
        }
        fs.delete(path, true)
    }

    private fun shell(command: String) {
        ParcelFileDescriptor.AutoCloseInputStream(
            InstrumentationRegistry.getInstrumentation().uiAutomation.executeShellCommand(command),
        ).use { it.readBytes() }
    }

    private fun ensureDeviceAwake() {
        shell("input keyevent KEYCODE_WAKEUP")
        shell("wm dismiss-keyguard")
    }

    private suspend fun await(label: String, timeoutMs: Long, predicate: suspend () -> Boolean) {
        try {
            withTimeout(timeoutMs) { while (!predicate()) delay(100) }
        } catch (e: kotlinx.coroutines.TimeoutCancellationException) {
            throw AssertionError("$label did not finish within ${timeoutMs}ms", e)
        }
    }

    private suspend fun <T : Any> awaitValue(label: String, timeoutMs: Long, value: () -> T?): T {
        var result: T? = null
        await(label, timeoutMs) { value()?.also { result = it } != null }
        return requireNotNull(result)
    }

    private fun join(parent: String, child: String): String = if (parent == "/") "/$child" else "${parent.trimEnd('/')}/$child"

    private companion object { const val MIB = 1024L * 1024L }
}
