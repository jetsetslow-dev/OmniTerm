package com.jetsetslow.omniterm

import android.app.Application
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.jetsetslow.omniterm.data.AppDatabase
import com.jetsetslow.omniterm.data.AppRepository
import com.jetsetslow.omniterm.data.NetworkShareEntity
import com.jetsetslow.omniterm.data.shares.ShareClients
import com.jetsetslow.omniterm.data.ssh.SshHostKeyTrust
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.security.MessageDigest
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith

/** Destructive only inside uniquely named directories on the disposable SMB/FTP/SFTP/WebDAV lab. */
@RunWith(AndroidJUnit4::class)
class E2eRemoteFilesStressTest {
    @Test
    fun everyRemoteFilesystemSupportsLosslessMutationAndCleanup() = runBlocking {
        assumeTrue(
            InstrumentationRegistry.getArguments().getString("omniterm_e2e_remote_files") == "yes",
        )
        val app = InstrumentationRegistry.getInstrumentation().targetContext.applicationContext as Application
        val repository = AppRepository(AppDatabase.getDatabase(app))
        // This suite deliberately exercises the filesystem clients without launching an Activity.
        // Normal app startup performs this initialization through AppViewModel.
        SshHostKeyTrust.init(app)
        val shares = repository.getAllNetworkShares()
            .filter { it.name.startsWith("E2E ") }
            .map { share ->
                if (share.protocol.equals("WEBDAV", ignoreCase = true) &&
                    (!share.useHttps || share.port != WEB_DAV_TLS_PORT)
                ) {
                    // Upgrade profiles created by the earlier cleartext lab seed. Release code
                    // intentionally refuses that insecure configuration before sending credentials.
                    share.copy(port = WEB_DAV_TLS_PORT, useHttps = true)
                        .also { repository.updateNetworkShare(it) }
                } else {
                    share
                }
            }
        assertEquals(setOf("SMB", "FTP", "SFTP", "WEBDAV"), shares.map { it.protocol.uppercase() }.toSet())

        val runId = System.currentTimeMillis().toString(36)
        for (share in shares.sortedBy { it.protocol }) {
            withTimeout(60_000) { exerciseShare(share, runId) }
        }
    }

    private suspend fun exerciseShare(share: NetworkShareEntity, runId: String) {
        val client = ShareClients.forShare(share, share.username, share.password)
        val protocol = share.protocol.uppercase()
        val rootName = "omniterm-e2e-$runId-${protocol.lowercase()}"
        var root = ""
        val originalName = "space-λ-$runId.bin"
        val renamedName = "renamed-雪-$runId.bin"
        val nestedName = "nested folder"
        val original = payload(2 * 1024 * 1024, 17)
        val replacement = payload(1024 * 1024 + 137, 91)
        try {
            val base = ShareClients.startPath(share, client).ifBlank { "/" }
            root = join(base, rootName)
            client.mkdir(root)
            assertTrue("$protocol root missing", client.list(base).any { it.name == rootName && it.isDirectory })

            val progress = mutableListOf<Long>()
            val originalPath = join(root, originalName)
            client.uploadStream(originalPath, ByteArrayInputStream(original), original.size.toLong()) { done, _ ->
                progress += done
            }
            assertTrue("$protocol upload progress missing", progress.size >= 2)
            assertTrue("$protocol upload progress regressed: $progress", progress.zipWithNext().all { it.first <= it.second })
            assertEquals(original.size.toLong(), progress.last())

            val firstDownload = ByteArrayOutputStream()
            val firstBytes = client.downloadTo(originalPath, firstDownload)
            assertEquals(original.size.toLong(), firstBytes)
            assertArrayEquals("$protocol first download mismatch", original, firstDownload.toByteArray())

            // Overwrite conflict semantics: the second upload must replace, never append.
            client.uploadStream(originalPath, ByteArrayInputStream(replacement), replacement.size.toLong())
            val overwritten = ByteArrayOutputStream()
            assertEquals(replacement.size.toLong(), client.downloadTo(originalPath, overwritten))
            assertArrayEquals("$protocol overwrite mismatch", replacement, overwritten.toByteArray())
            assertEquals(sha256(replacement), sha256(overwritten.toByteArray()))

            val renamedPath = join(root, renamedName)
            client.rename(originalPath, renamedPath)
            val rootListing = client.list(root)
            assertTrue("$protocol renamed file missing", rootListing.any { it.name == renamedName && !it.isDirectory })
            assertTrue("$protocol old name survived rename", rootListing.none { it.name == originalName })

            val nested = join(root, nestedName)
            client.mkdir(nested)
            val emptyPath = join(nested, "empty-文件.txt")
            client.uploadStream(emptyPath, ByteArrayInputStream(ByteArray(0)), 0)
            assertTrue("$protocol empty file missing", client.list(nested).any { it.name == "empty-文件.txt" && it.size == 0L })

            client.delete(emptyPath, isDirectory = false)
            client.delete(nested, isDirectory = true)
            client.delete(renamedPath, isDirectory = false)
            client.delete(root, isDirectory = true)
            assertTrue("$protocol cleanup left $rootName", client.list(base).none { it.name == rootName })
            root = ""
        } finally {
            if (root.isNotBlank()) {
                // Best-effort reverse cleanup for assertion failures; each operation is isolated so
                // one missing path cannot prevent later disposable artifacts from being removed.
                runCatching { client.delete(join(join(root, nestedName), "empty-文件.txt"), false) }
                runCatching { client.delete(join(root, nestedName), true) }
                runCatching { client.delete(join(root, originalName), false) }
                runCatching { client.delete(join(root, renamedName), false) }
                runCatching { client.delete(root, true) }
            }
            client.close()
        }
    }

    private fun join(parent: String, child: String): String =
        if (parent == "/") "/$child" else "${parent.trimEnd('/')}/$child"

    private fun payload(size: Int, seed: Int): ByteArray =
        ByteArray(size) { index -> ((index * 31 + seed) and 0xff).toByte() }

    private fun sha256(bytes: ByteArray): String =
        MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }

    private companion object {
        const val WEB_DAV_TLS_PORT = 8443
    }
}
