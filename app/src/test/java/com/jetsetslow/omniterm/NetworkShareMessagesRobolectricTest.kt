package com.jetsetslow.omniterm

import android.app.Application
import androidx.lifecycle.ViewModelStore
import androidx.test.core.app.ApplicationProvider
import com.jetsetslow.omniterm.data.AppDatabase
import com.jetsetslow.omniterm.data.AppRepository
import com.jetsetslow.omniterm.data.NetworkShareEntity
import com.jetsetslow.omniterm.data.ssh.SshCredentials
import com.jetsetslow.omniterm.data.ssh.SshTransport
import com.jetsetslow.omniterm.data.ssh.TerminalSession
import com.jetsetslow.omniterm.ui.AppViewModel
import com.jetsetslow.omniterm.ui.NetworkShareScanHit
import com.jetsetslow.omniterm.ui.scanPrefixOf
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.asCoroutineDispatcher
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.setMain
import kotlinx.coroutines.withContext
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import java.util.concurrent.Executors

/**
 * The Network Shares tab says what a save, delete or check did, without the scan dialog open.
 *
 * These results used to be written only to the scan dialog's status line, so outside that dialog a
 * failed save said nothing at all. Flutter shows them in a card above the list, and so does this.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
@OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)
class NetworkShareMessagesRobolectricTest {
    @Test
    fun savingAndDeletingAShareSayWhatHappened() = withModel { model, main ->
        val share = NetworkShareEntity(name = "media", protocol = "FTP", address = "192.0.2.9", port = 21)
        withContext(main) { model.saveNetworkShare(share) }
        waitWhileOnMain(main) { model.networkShareMessage == null }
        assertEquals("Saved media.", model.networkShareMessage)
        assertFalse(model.networkShareMessageIsError)
        assertNull("the scan dialog's line is the scan's alone", model.networkShareScanStatus)

        val repository = AppRepository(AppDatabase.getDatabase(ApplicationProvider.getApplicationContext<Application>()))
        val saved = repository.getAllNetworkShares().single { it.name == "media" && it.address == "192.0.2.9" }
        withContext(main) { model.deleteNetworkShare(saved) }
        waitWhileOnMain(main) { model.networkShareMessage != "Deleted media." }

        withContext(main) { model.dismissNetworkShareMessage() }
        assertNull(model.networkShareMessage)
    }

    @Test
    fun aShareThatCannotBeSavedSaysWhyOnTheTab() = withModel { model, main ->
        withContext(main) { model.saveNetworkShare(NetworkShareEntity(name = "office", protocol = "SMB", address = "192.0.2.10")) }
        waitWhileOnMain(main) { model.networkShareMessage == null }
        assertEquals("SMB shares need a Share/path value such as Public or Media.", model.networkShareMessage)
        assertTrue(model.networkShareMessageIsError)
        assertNull("the scan dialog's line is the scan's alone", model.networkShareScanStatus)
    }

    @Test
    fun savingAScanHitSaysSoInTheScanDialog() = withModel { model, main ->
        val hit = NetworkShareScanHit(address = "192.0.2.11", protocol = "FTP", port = 21)
        withContext(main) {
            model.networkShareScanHits.add(hit)
            model.addNetworkShareFromScan(hit)
        }
        // Saved hits leave the list, so the dialog only offers what is not saved yet.
        waitWhileOnMain(main) { hit in model.networkShareScanHits }
        assertEquals("Saved FTP on 192.0.2.11:21.", withContext(main) { model.networkShareScanStatus })
    }

    @Test
    fun theScanSubnetIsPrefilledOnceFromASavedShare() = withModel { model, main ->
        withContext(main) {
            model.prepareNetworkShareScan(
                listOf(
                    NetworkShareEntity(name = "nas", address = "nas.local"),
                    NetworkShareEntity(name = "media", address = "192.168.7.20"),
                ),
            )
            assertEquals("192.168.7.0/24", model.networkShareScanCidr)

            // Cleared by the user, it stays cleared: blank scans this device's own network.
            model.networkShareScanCidr = ""
            model.prepareNetworkShareScan(listOf(NetworkShareEntity(name = "media", address = "10.0.0.5")))
            assertEquals("", model.networkShareScanCidr)
        }
    }

    @Test
    fun aSubnetPrefixIsReadFromWhatPeopleType() {
        assertEquals("192.168.1", scanPrefixOf("192.168.1.0/24"))
        assertEquals("192.168.1", scanPrefixOf(" 192.168.1.20 "))
        assertEquals("192.168.1", scanPrefixOf("192.168.1"))
        assertNull(scanPrefixOf("nas.local"))
        assertNull(scanPrefixOf("192.168"))
        assertNull(scanPrefixOf("999.168.1.0"))
    }

    private fun withModel(body: suspend (AppViewModel, kotlinx.coroutines.CoroutineDispatcher) -> Unit) = runBlocking {
        // Real time: AppViewModel does its database work on Dispatchers.IO.
        val main = Executors.newSingleThreadExecutor().asCoroutineDispatcher()
        Dispatchers.setMain(main)
        val store = ViewModelStore()
        try {
            val application = ApplicationProvider.getApplicationContext<Application>()
            val model = withContext(main) { AppViewModel(application, IdleTransport()) }
            store.put("test", model)
            body(model, main)
        } finally {
            try {
                clearViewModelsAndAwaitTerminalJobs(store, main)
            } finally {
                Dispatchers.resetMain()
                main.close()
            }
        }
    }

    private class IdleTransport : SshTransport {
        override suspend fun exec(creds: SshCredentials, command: String, stdin: String?): String = ""

        override suspend fun execStream(
            creds: SshCredentials,
            command: String,
            stdin: String?,
            onChunk: suspend (String) -> Unit,
        ): String = ""

        override suspend fun testConnection(creds: SshCredentials): String? = null

        override suspend fun openShell(
            creds: SshCredentials,
            cols: Int,
            rows: Int,
            onPhaseChange: ((String) -> Unit)?,
        ): TerminalSession = IdleShell()
    }

    private class IdleShell : TerminalSession {
        override val output = MutableSharedFlow<ByteArray>(replay = 1)
        override val closed = MutableStateFlow(false)
        override val exitStatus = MutableStateFlow<Int?>(null)
        override val remoteExited = MutableStateFlow(false)
        override suspend fun write(bytes: ByteArray) = Unit
        override suspend fun resize(cols: Int, rows: Int) = Unit
        override fun close() { closed.value = true }
    }
}
