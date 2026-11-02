package com.jetsetslow.omniterm

import android.app.Application
import androidx.lifecycle.ViewModelStore
import androidx.test.core.app.ApplicationProvider
import com.jetsetslow.omniterm.data.AlertRuleEntity
import com.jetsetslow.omniterm.data.AppDatabase
import com.jetsetslow.omniterm.data.AppRepository
import com.jetsetslow.omniterm.data.HostDependentCounts
import com.jetsetslow.omniterm.data.PersistentSessionEntity
import com.jetsetslow.omniterm.data.PortForwardEntity
import com.jetsetslow.omniterm.data.ServerEntity
import com.jetsetslow.omniterm.data.StackRegistryEntity
import com.jetsetslow.omniterm.ui.AppViewModel
import com.jetsetslow.omniterm.ui.ConfirmController
import com.jetsetslow.omniterm.ui.hostDeleteMessage
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExecutorCoroutineDispatcher
import kotlinx.coroutines.asCoroutineDispatcher
import kotlinx.coroutines.delay
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

/**
 * Deleting a host deletes everything stored for it, and the dialog says what that is.
 *
 * A bookmark seemed to move to another host after its own was deleted. An empty star list was
 * filled with five suggested folders, and the first star on a host saved all five as its
 * bookmarks, so the list a deleted host had shown came back on the next host starred.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
@OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)
class HostDeleteCascadeRobolectricTest {

    @Test
    fun aStarOnAHostWithNothingSavedSavesOnlyThatFolder() = withHosts { model, repository, kept, other ->
        repository.insertSetting("sftp_bookmarks_$kept", "/srv/kept")
        onMain {
            model.selectedServerId = kept
            model.ensureSftpLoadedForSelectedServer()
        }
        awaitTrue { onMain { model.sftpBookmarks.toList() } == listOf("/srv/kept") }

        onMain {
            model.selectedServerId = other
            model.ensureSftpLoadedForSelectedServer()
        }
        awaitTrue { model.sftpError != null }
        assertEquals("Nothing is starred on a host with nothing saved", emptyList<String>(), onMain { model.sftpBookmarks.toList() })

        onMain { model.addSftpBookmark("/srv/other") }
        awaitTrue { repository.getSetting("sftp_bookmarks_$other") != null }
        assertEquals("/srv/other", repository.getSetting("sftp_bookmarks_$other"))
        assertEquals("/srv/kept", repository.getSetting("sftp_bookmarks_$kept"))
        awaitTrue { onMain { model.sftpBookmarks.toList() } == listOf("/srv/other") }
    }

    @Test
    fun deletingAHostListsAndRemovesEverythingStoredForIt() = withHosts { model, repository, kept, doomed ->
        repository.insertSetting("sftp_bookmarks_$doomed", "/srv/a|||/srv/b")
        repository.insertSetting("sftp_bookmarks_$kept", "/srv/kept")
        repository.insertPortForward(PortForwardEntity(serverId = doomed, name = "Web", bindPort = 18080))
        repository.insertRule(AlertRuleEntity(serverId = doomed, metricName = "CPU Usage", thresholdValue = 90f, severity = "WARNING"))
        repository.upsertPersistentSession(PersistentSessionEntity("omniterm-1", doomed, "Doomed"))
        repository.upsertStacks(listOf(StackRegistryEntity(serverId = doomed, runtime = "docker", project = "web", workingDir = "/srv", configFiles = "/srv/compose.yml")))

        val counts = model.hostDeletionCounts(setOf(doomed))
        assertEquals(HostDependentCounts(bookmarks = 2, tunnels = 1, alertRules = 1, savedTmuxSessions = 1, composeStacks = 1), counts)
        val confirm = ConfirmController().apply { resources = ApplicationProvider.getApplicationContext<Application>().resources }
        assertEquals(
            "Lead.\n\nAlso deleted from OmniTerm:\n" +
                "• 2 Files bookmarks\n• 1 saved tunnel\n• 1 alert rule\n• 1 saved tmux session\n" +
                "• 1 recorded Compose stack\n• Monitoring and alert history, and launcher shortcuts",
            hostDeleteMessage(confirm, "Lead.", counts),
        )
        assertEquals(
            "Only what is there is listed",
            "Lead.\n\nAlso deleted from OmniTerm:\n• 1 trusted host key\n• Monitoring and alert history, and launcher shortcuts",
            hostDeleteMessage(confirm, "Lead.", HostDependentCounts(trustedHostKeys = 1)),
        )

        onMain {
            model.selectedServerId = doomed
            model.ensureSftpLoadedForSelectedServer()
            model.loadAllBookmarks()
        }
        awaitTrue { onMain { model.allBookmarks.size } == 3 && onMain { model.sftpBookmarks.size } == 2 }

        onMain { model.deleteServer(checkNotNull(model.servers.value.first { it.id == doomed })) }
        awaitTrue { repository.getServerById(doomed) == null }
        assertNull(repository.getSetting("sftp_bookmarks_$doomed"))
        assertTrue(repository.getAllPortForwards().none { it.serverId == doomed })
        assertTrue(repository.getAllRules().none { it.serverId == doomed })
        assertTrue(repository.getPersistentSessions().none { it.serverId == doomed })
        assertTrue(repository.getStacksForServer(doomed).isEmpty())
        assertEquals(HostDependentCounts(), model.hostDeletionCounts(setOf(doomed)))
        onMain {
            assertEquals(listOf("/srv/kept"), model.allBookmarks.map { it.path })
            assertEquals(emptyList<String>(), model.sftpBookmarks.toList())
        }

        // The host left selected gets its own list, and a star adds to it alone.
        onMain {
            model.selectedServerId = kept
            model.ensureSftpLoadedForSelectedServer()
        }
        awaitTrue { onMain { model.sftpBookmarks.toList() } == listOf("/srv/kept") }
        onMain { model.addSftpBookmark("/srv/new") }
        awaitTrue { repository.getSetting("sftp_bookmarks_$kept") == "/srv/kept|||/srv/new" }
    }

    private lateinit var main: ExecutorCoroutineDispatcher

    private suspend fun <T> onMain(block: () -> T): T = withContext(main) { block() }

    private suspend fun awaitTrue(condition: suspend () -> Boolean) = withTimeout(10_000) {
        while (!condition()) delay(10)
    }

    private fun withHosts(block: suspend (AppViewModel, AppRepository, Int, Int) -> Unit) = runBlocking {
        // Real time: AppViewModel deliberately does database work on Dispatchers.IO.
        main = Executors.newSingleThreadExecutor().asCoroutineDispatcher()
        Dispatchers.setMain(main)
        val store = ViewModelStore()
        try {
            val application = ApplicationProvider.getApplicationContext<Application>()
            val db = AppDatabase.getDatabase(application)
            withContext(Dispatchers.IO) { db.clearAllTables() }
            val repository = AppRepository(db)
            // Port 1 on this machine refuses at once, so opening Files fails without a wait.
            val ids = listOf("Kept", "Doomed").map { name ->
                repository.insertServer(ServerEntity(name = name, host = "127.0.0.1", port = 1, username = "fixture")).toInt()
            }
            val model = withContext(main) { AppViewModel(application, QuietHosts()) }
            store.put("test", model)
            awaitTrue { model.servers.value.count { it.id in ids } == 2 }
            block(model, repository, ids[0], ids[1])
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
