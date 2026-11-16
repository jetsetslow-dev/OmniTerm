package com.jetsetslow.omniterm

import android.net.Uri
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
import kotlinx.coroutines.withTimeoutOrNull
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Rule
import org.junit.Test

/**
 * Destructive only inside unique directories on the disposable lab. The suite saves its own four
 * shares and one host on the repository's fixtures, at `network_host`, the address the phone's own
 * network reaches them at (10.0.2.2 from the emulator): FTP, SMB and WebDAV on the shares fixture,
 * SFTP on the lab host. Run with `./scripts/test-hosts.sh suite E2eFileTransferLifecycleStressTest
 * omniterm_e2e_transfer_lifecycle=yes network_host port user pass omniterm_e2e_sftp_home`.
 *
 * It stays opt-in and fails, at its end, on two open SMB defects (Nov 16, WORK_PROGRESS.md):
 * cancelling an SMB upload takes about 15.7 s, past the 12 s bound, and an SMB upload cancelled
 * while the phone is offline leaves its hidden staging file on the share. Every other check passes.
 */
class E2eFileTransferLifecycleStressTest {
    @get:Rule
    val composeRule = createAndroidComposeRule<MainActivity>()

    @Test
    fun transfersCancelRecoverRetryAndCrossEndpointsWithoutPartialData() = runBlocking {
        assumeTrue(E2eArgs.on("omniterm_e2e_transfer_lifecycle"))
        ensureDeviceAwake()
        composeRule.activityRule.scenario.moveToState(Lifecycle.State.RESUMED)
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        val vm = ViewModelProvider(composeRule.activity)[AppViewModel::class.java]
        val repository = AppRepository(AppDatabase.getDatabase(context))
        val network = E2eArgs.require("network_host")
        val port = E2eArgs.get("port")?.toIntOrNull() ?: 2205
        val user = E2eArgs.require("user")
        val pass = E2eArgs.require("pass")
        suspend fun removeShares() = repository.getAllNetworkShares().filter { it.name.startsWith(PREFIX) }.forEach { repository.deleteNetworkShare(it) }
        removeShares()
        // As a user adds them: the shares fixture's FTP, SMB (its "fixture" share) and WebDAV (plain
        // HTTP under /fixture), and SFTP on the lab host, which opens in the user's home.
        listOf(
            NetworkShareEntity(name = "$PREFIX FTP", protocol = "FTP", address = network, port = 21, sharePath = "/"),
            NetworkShareEntity(name = "$PREFIX SMB", protocol = "SMB", address = network, port = 445, sharePath = "fixture", workgroup = "WORKGROUP"),
            NetworkShareEntity(name = "$PREFIX WebDAV", protocol = "WEBDAV", address = network, port = 8082, sharePath = "/fixture"),
            NetworkShareEntity(name = "$PREFIX SFTP", protocol = "SFTP", address = network, port = port),
        ).forEach { repository.insertNetworkShare(it.copy(username = user, password = pass, anonymous = false)) }
        val shares = repository.getAllNetworkShares().filter { it.name.startsWith(PREFIX) }.sortedBy { it.protocol }
        assertEquals(setOf("FTP", "SMB", "SFTP", "WEBDAV"), shares.map { it.protocol.uppercase() }.toSet())
        // The lab host for the dual-pane part; connecting once also trusts the SFTP share's host key.
        val host = E2eLabHosts.add(vm, HOST, network, port, user, pass).also { E2eLabHosts.connectOnce(vm, it) }
        var offline: PhoneOffline? = null
        // Cancels that ended, but later than their bound: reported together at the end, so the
        // checks after them still run (an SMB upload takes about 15.7 s to cancel on the fixture).
        val slowCancels = mutableListOf<String>()
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
                val cancelledAt = System.nanoTime()
                vm.cancelSftpTransfer(row.id)
                awaitCancelled(vm, row.id, "${share.protocol} upload", cancelledAt, 12_000, slowCancels)
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
            val downloadCancelledAt = System.nanoTime()
            vm.cancelSftpTransfer(downloadRow.id)
            awaitCancelled(vm, downloadRow.id, "SFTP download", downloadCancelledAt, 12_000, slowCancels)
            if (vm.sftpTransfers.find { it.id == downloadRow.id }?.status == SftpTransferStatus.Failure) {
                assertTrue("partial SAF download was not deleted", downloadUri.toString() in SlowTransferContentProvider.deletedUris)
            }

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

            // A real network loss during an active upload, followed by a user cancellation, must
            // return control within the same bound even if a protocol socket would otherwise wait
            // longer. SMB, whose one connection the loss takes away: FTP's data connection would not
            // go, as the fixture names 127.0.0.1 for it, which on the emulator is adb's reverse port.
            val smbRoot = requireNotNull(roots[smb])
            openShare(vm, smb, smbRoot)
            val lossName = "network-loss.bin"
            val lossUri = slowUri(authority, "upload", lossName, 64L * MIB, delayMs = 5)
            vm.shareUploadMany(listOf(lossUri), context)
            val lossRow = awaitRunning(vm, lossName)
            await("upload progress before the network loss", 20_000) {
                vm.sftpTransfers.find { it.id == lossRow.id }?.bytesTransferred ?: 0L >= 512 * 1024
            }
            offline = PhoneOffline()
            delay(2_000)
            assertFalse("the share is still reachable with the phone offline", canList(smb, smbRoot))
            val lossCancelledAt = System.nanoTime()
            vm.cancelSftpTransfer(lossRow.id)
            offline?.close()
            offline = null
            awaitCancelled(vm, lossRow.id, "SMB upload during the network loss", lossCancelledAt, 15_000, slowCancels)
            await("the share back after the network", 30_000) { canList(smb, smbRoot) }
            client(smb).use { fs ->
                val names = fs.list(smbRoot).map { it.name }
                assertFalse(lossName in names)
                // Reported at the end with the slow cancels, so the checks after it still run.
                names.filter { ".omniterm-part-" in it }.forEach { slowCancels += "SMB kept the staging file $it after the network loss" }
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
            val labDir = (E2eArgs.get("omniterm_e2e_sftp_home") ?: "/home/${host.username}") + "/omniterm-e2e"
            vm.selectedServerId = host.id
            vm.loadSftp(labDir)
            await("primary SFTP pane", 25_000) { !vm.sftpLoading && vm.sftpError.isNullOrBlank() }
            val primaryPath = vm.sftpPath
            if (!vm.dualPaneEnabled) vm.toggleDualPane()
            vm.paneBSelectServer(host.id)
            vm.loadPaneB(labDir)
            await("secondary SFTP pane", 25_000) { !vm.paneBLoading && vm.paneBError.isNullOrBlank() }
            val nested = vm.paneBEntries.firstOrNull { it.isDirectory }
            if (nested != null) {
                vm.paneBNavigateInto(nested.name)
                await("secondary nested navigation", 25_000) { !vm.paneBLoading && vm.paneBPath.endsWith("/${nested.name}") }
                assertEquals(primaryPath, vm.sftpPath)
                vm.paneBNavigateUp()
                await("secondary navigate up", 25_000) { !vm.paneBLoading && vm.paneBPath == primaryPath }
            }
            assertTrue("cancels over their bound, or what they left: $slowCancels", slowCancels.isEmpty())
        } finally {
            offline?.close()
            composeRule.runOnUiThread {
                vm.cancelAllRunningTransfers()
                vm.closeShareBrowser()
            }
            for ((share, root) in roots.entries.reversed()) {
                runCatching { client(share).use { deleteTree(it, root) } }
            }
            removeShares()
            E2eLabHosts.remove(vm, HOST)
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

    private fun ensureDeviceAwake() {
        DeviceShell.run("input keyevent KEYCODE_WAKEUP")
        DeviceShell.run("wm dismiss-keyguard")
    }

    private suspend fun await(label: String, timeoutMs: Long, predicate: suspend () -> Boolean) {
        try {
            withTimeout(timeoutMs) { while (!predicate()) delay(100) }
        } catch (e: kotlinx.coroutines.TimeoutCancellationException) {
            throw AssertionError("$label did not finish within ${timeoutMs}ms", e)
        }
    }

    /**
     * Waits for the cancelled transfer [rowId] to end as failed, a minute at most. One that took
     * [boundMs] or longer from [cancelledAt] (System.nanoTime), or had not ended after the minute,
     * is added to [slow] with what its row showed.
     */
    private suspend fun awaitCancelled(vm: AppViewModel, rowId: String, label: String, cancelledAt: Long, boundMs: Long, slow: MutableList<String>) {
        val ended = withTimeoutOrNull(60_000) {
            while (vm.sftpTransfers.find { it.id == rowId }?.status != SftpTransferStatus.Failure) delay(100)
        } != null
        val tookMs = (System.nanoTime() - cancelledAt) / 1_000_000
        val row = vm.sftpTransfers.find { it.id == rowId }
        when {
            !ended -> slow += "$label had not ended $tookMs ms after the cancel (${row?.status}, ${row?.bytesTransferred} bytes)"
            tookMs >= boundMs -> slow += "$label $tookMs ms (bound ${boundMs / 1000} s)"
        }
    }

    private suspend fun <T : Any> awaitValue(label: String, timeoutMs: Long, value: () -> T?): T {
        var result: T? = null
        await(label, timeoutMs) { value()?.also { result = it } != null }
        return requireNotNull(result)
    }

    private fun join(parent: String, child: String): String = if (parent == "/") "/$child" else "${parent.trimEnd('/')}/$child"

    private companion object {
        const val MIB = 1024L * 1024L
        const val PREFIX = "E2E transfer"
        const val HOST = "E2E transfer host"
    }
}
