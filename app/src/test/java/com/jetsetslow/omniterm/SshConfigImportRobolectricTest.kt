package com.jetsetslow.omniterm

import android.app.Application
import androidx.lifecycle.ViewModelStore
import androidx.test.core.app.ApplicationProvider
import com.jetsetslow.omniterm.data.AppDatabase
import com.jetsetslow.omniterm.data.AppRepository
import com.jetsetslow.omniterm.data.ServerEntity
import com.jetsetslow.omniterm.data.SshConfigParser
import com.jetsetslow.omniterm.data.SshKeyEntity
import com.jetsetslow.omniterm.ui.AppViewModel
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.asCoroutineDispatcher
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.setMain
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import java.util.concurrent.Executors

/** Hosts imported from an ssh_config file are saved as the user would have entered them. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
@OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)
class SshConfigImportRobolectricTest {

    @Test
    fun hostsAreSavedWithTheirKeyJumpHostAndSettingsAndDuplicatesAreLeftAlone() = runBlocking {
        // Real time: AppViewModel deliberately does database work on Dispatchers.IO.
        val main = Executors.newSingleThreadExecutor().asCoroutineDispatcher()
        Dispatchers.setMain(main)
        val store = ViewModelStore()
        try {
            val application = ApplicationProvider.getApplicationContext<Application>()
            val db = AppDatabase.getDatabase(application)
            withContext(Dispatchers.IO) { db.clearAllTables() }
            val repository = AppRepository(db)
            // Only its name matters here; an empty private key needs no Keystore to save.
            repository.insertKey(SshKeyEntity(alias = "id_ed25519", keyType = "Ed25519", privateKey = "", publicKey = "p", fingerprint = "f"))
            // Port 1 on this machine refuses at once, so the probe after saving does not wait.
            repository.insertServer(ServerEntity(name = "existing", host = "127.0.0.1", port = 1, username = "taken"))
            val model = withContext(main) { AppViewModel(application, QuietHosts()) }
            store.put("test", model)

            val file = SshConfigParser.parse(
                """
                Host bastion
                  HostName 127.0.0.2
                  Port 1
                  User jump
                  IdentityFile ~/.ssh/id_ed25519
                Host web
                  HostName 127.0.0.1
                  Port 1
                  User deploy
                  IdentityFile ~/.ssh/id_ed25519.pub
                  ProxyJump bastion
                  ForwardAgent yes
                  ServerAliveInterval 15
                Host nas
                  HostName 127.0.0.3
                  Port 1
                  IdentityFile ~/.ssh/nas_key
                Host existing
                  HostName 127.0.0.1
                  Port 1
                  User taken
                """.trimIndent(),
            )
            val summary = CompletableDeferred<String>()
            withContext(main) { model.importSshConfigHosts(file.hosts, defaultUser = "admin") { summary.complete(it) } }

            assertEquals(
                "Imported 3 hosts. Not imported: existing: already saved as \"existing\".",
                withTimeout(10_000) { summary.await() },
            )
            val saved = repository.getAllServers().associateBy { it.name }
            val web = saved.getValue("web")
            assertEquals("key", web.authType)
            assertEquals("the saved key named like its IdentityFile", "id_ed25519", web.authKeyAlias)
            assertEquals("ssh", web.proxyType)
            assertEquals("127.0.0.2", web.proxyHost)
            assertEquals("jump", web.proxyUser)
            assertEquals("id_ed25519", web.proxyKeyAlias)
            assertTrue(web.agentForwarding)
            assertEquals(15, web.keepAlive)

            val nas = saved.getValue("nas")
            assertEquals("the default user fills in", "admin", nas.username)
            assertEquals("password", nas.authType)
            assertNull(nas.authKeyAlias)
            assertTrue(nas.notes, nas.notes.contains("Its key ~/.ssh/nas_key is not saved in OmniTerm"))
            assertEquals(4, saved.size)
        } finally {
            try {
                clearViewModelsAndAwaitTerminalJobs(store, main)
            } finally {
                Dispatchers.resetMain()
                main.close()
            }
        }
    }
}
