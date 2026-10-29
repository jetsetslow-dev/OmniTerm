package com.jetsetslow.omniterm

import android.app.Application
import androidx.lifecycle.ViewModelStore
import androidx.test.core.app.ApplicationProvider
import com.jcraft.jsch.HostKeyRepository
import com.jetsetslow.omniterm.data.AppDatabase
import com.jetsetslow.omniterm.data.AppRepository
import com.jetsetslow.omniterm.data.ServerEntity
import com.jetsetslow.omniterm.data.ssh.SshCredentials
import com.jetsetslow.omniterm.data.ssh.SshHostKeyTrust
import com.jetsetslow.omniterm.data.ssh.SshTransport
import com.jetsetslow.omniterm.data.ssh.TerminalSession
import com.jetsetslow.omniterm.ui.AppViewModel
import com.jetsetslow.omniterm.ui.TerminalSessionManager
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.asCoroutineDispatcher
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.setMain
import kotlinx.coroutines.withContext
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import java.io.IOException
import java.util.concurrent.Executors

/**
 * Rejecting a host's first key fails only what was waiting on it. From the terminal, the connect
 * fails with "Host key verification failed." and no "Host key changed" warning, since nothing
 * changed; connecting again asks again. From a background check, the terminal is left alone, and
 * later background checks stop asking about that key.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
@OptIn(ExperimentalCoroutinesApi::class)
class HostKeyRejectionRobolectricTest {

    @Test
    fun rejectingAFirstKeyFromTheTerminalFailsItWithoutCallingTheKeyChanged() = withModel { model, transport, main ->
        repeat(2) { attempt ->
            withContext(main) { model.connectTerminal() }
            // The second connect asks again: the user starting it is asking to be asked.
            waitWhileOnMain(main, 10_000) { model.pendingHostKeyApproval == null }
            withContext(main) { model.approveHostKey(false) }
            waitWhileOnMain(main, 10_000) { model.isTerminalConnecting }
            withContext(main) {
                assertEquals("attempt $attempt", "Host key verification failed.", model.terminalConnectError)
                assertNull("a key the user turned down has not changed", model.hostKeyChangedServer)
            }
        }
        assertEquals(2, transport.checks)
    }

    @Test
    fun aKeyThatNoLongerMatchesOffersToRemoveIt() = withModel { model, transport, main ->
        transport.keyChanged = true
        withContext(main) { model.connectTerminal() }
        waitWhileOnMain(main, 10_000) { model.isTerminalConnecting || model.hostKeyChangedServer == null }
        withContext(main) {
            assertEquals("Host key verification failed.", model.terminalConnectError)
            assertEquals(model.selectedServerId, model.hostKeyChangedServer?.id)
        }
    }

    @Test
    fun rejectingABackgroundChecksKeyLeavesTheTerminalAlone() = withModel { model, _, main ->
        val first = async(Dispatchers.IO) { checkFixtureKey() }
        waitWhileOnMain(main, 10_000) { model.pendingHostKeyApproval == null }
        withContext(main) { model.approveHostKey(false) }
        assertEquals(HostKeyRepository.NOT_INCLUDED, first.await())
        withContext(main) {
            assertNull(model.terminalConnectError)
            assertEquals(false, model.isTerminalConnecting)
        }

        assertEquals("the same key fails closed without asking", HostKeyRepository.NOT_INCLUDED, checkFixtureKey())
        assertNull(withContext(main) { model.pendingHostKeyApproval })
    }

    private fun withModel(
        body: suspend kotlinx.coroutines.CoroutineScope.(AppViewModel, KeyCheckingTransport, CoroutineDispatcher) -> Unit,
    ) = runBlocking<Unit> {
        val main = Executors.newSingleThreadExecutor().asCoroutineDispatcher()
        Dispatchers.setMain(main)
        val store = ViewModelStore()
        val transport = KeyCheckingTransport()
        var repository: AppRepository? = null
        var serverId: Int? = null
        try {
            TerminalSessionManager.clearAll()
            val application = ApplicationProvider.getApplicationContext<Application>()
            val repo = AppRepository(AppDatabase.getDatabase(application))
            repository = repo
            val id = repo.insertServer(ServerEntity(name = "Key fixture", host = HOST, username = "fixture")).toInt()
            serverId = id
            val model = withContext(main) { AppViewModel(application, transport) }
            store.put("test", model)
            waitWhileOnMain(main, 10_000) { model.servers.value.none { it.id == id } }
            withContext(main) { model.selectedServerId = id }
            body(model, transport, main)
        } finally {
            try {
                clearViewModelsAndAwaitTerminalJobs(store, main)
                repository?.let { repo -> serverId?.let { repo.getServerById(it)?.let { row -> repo.deleteServer(row) } } }
            } finally {
                SshHostKeyTrust.allowPromptAgain(HOST, 22)
                Dispatchers.resetMain()
                main.close()
            }
        }
    }

    /**
     * Opens no shell: each attempt runs the real first-key check, as JSch would, and fails the way
     * JSch does. Every command waits for good, so background probes never ask about the key.
     */
    private class KeyCheckingTransport : SshTransport {
        @Volatile var keyChanged = false
        @Volatile var checks = 0
            private set

        override suspend fun exec(creds: SshCredentials, command: String, stdin: String?): String = awaitCancellation()

        override suspend fun execStream(
            creds: SshCredentials,
            command: String,
            stdin: String?,
            onChunk: suspend (String) -> Unit,
        ): String = awaitCancellation()

        override suspend fun testConnection(creds: SshCredentials): String? = awaitCancellation()

        override suspend fun openShell(
            creds: SshCredentials,
            cols: Int,
            rows: Int,
            onPhaseChange: ((String) -> Unit)?,
        ): TerminalSession {
            if (keyChanged) throw IOException("HostKey has been changed: $HOST")
            checks++
            check(withContext(Dispatchers.IO) { checkFixtureKey() } == HostKeyRepository.NOT_INCLUDED)
            throw IOException("reject HostKey: $HOST")
        }
    }

    private companion object {
        const val HOST = "key-fixture.invalid"

        /** An ssh-ed25519 public key blob: the type name, then a 32-byte key. */
        val ED25519_KEY: ByteArray = run {
            val type = "ssh-ed25519".toByteArray()
            fun length(n: Int) = byteArrayOf(0, 0, 0, n.toByte())
            length(type.size) + type + length(32) + ByteArray(32) { it.toByte() }
        }

        fun checkFixtureKey(): Int = SshHostKeyTrust.repository().check(HOST, ED25519_KEY)
    }
}
