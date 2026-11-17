package com.jetsetslow.omniterm

import android.app.Application
import android.net.Uri
import androidx.lifecycle.ViewModelStore
import androidx.test.core.app.ApplicationProvider
import com.jetsetslow.omniterm.data.AppDatabase
import com.jetsetslow.omniterm.data.AppRepository
import com.jetsetslow.omniterm.data.FleetRunHistory
import com.jetsetslow.omniterm.data.ServerEntity
import com.jetsetslow.omniterm.ui.AppViewModel
import com.jetsetslow.omniterm.ui.BroadcastStatus
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.asCoroutineDispatcher
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.setMain
import kotlinx.coroutines.withContext
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import java.io.File
import java.util.concurrent.Executors

/**
 * A file pushed to several hosts as one Fleet run: each host gets the whole file or keeps what it
 * had, its card says which, the run is in History as a push, and Retry pushes the same bytes to
 * the hosts that failed.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
@OptIn(ExperimentalCoroutinesApi::class)
class FleetPushRobolectricTest {

    @Test
    fun aPushReachesEachHostWholeOrNotAtAllAndRetryFinishesIt() = runBlocking {
        val main = Executors.newSingleThreadExecutor().asCoroutineDispatcher()
        Dispatchers.setMain(main)
        val store = ViewModelStore()
        val application = ApplicationProvider.getApplicationContext<Application>()
        val db = AppDatabase.getDatabase(application)
        val repo = AppRepository(db)
        // a: has the folder, and an older copy of the file. b: its home cannot be read yet.
        // c: the folder is there, but only half of what is sent arrives.
        val a = MemoryHost("/home/a", listOf("/", "/home", "/home/a", "/home/a/conf")).apply { files["/home/a/conf/app.conf"] = "old".toByteArray() }
        val b = MemoryHost("/home/b", listOf("/", "/home"))
        val c = MemoryHost("/home/c", listOf("/", "/home", "/home/c", "/home/c/conf")).apply { short = true }
        val hosts = mapOf("a" to a, "b" to b, "c" to c)
        try {
            withContext(Dispatchers.IO) { db.clearAllTables() }
            val ids = hosts.keys.map { name ->
                repo.insertServer(ServerEntity(name = name, host = "$name.invalid", username = "u", status = "online")).toInt()
            }
            val model = withContext(main) { AppViewModel(application, QuietHosts()) { srv -> hosts.getValue(srv.name) } }
            store.put("push", model)
            waitWhileOnMain(main, 10_000) { model.servers.value.size < 3 }

            val source = File(application.filesDir, "app.conf").apply { writeText(CONTENT) }
            withContext(main) { model.pickFleetPushFile(Uri.fromFile(source)) }
            waitWhileOnMain(main, 10_000) { model.fleetPushReading || model.fleetPushPick == null && model.fleetPushError == null }
            assertNotNull(model.fleetPushError, model.fleetPushPick)
            val pick = model.fleetPushPick!!
            assertEquals("app.conf", pick.fileName)
            assertEquals(CONTENT.length.toLong(), pick.size)

            // "~/conf" names a folder on the hosts that have one, so the file goes inside it.
            withContext(main) {
                model.fleetPushDestination = "~/conf"
                model.runFleetPush(ids)
                model.clearFleetPushPick()
            }
            waitWhileOnMain(main, 10_000) { model.isBroadcastExecuting }

            val cards = model.broadcastResults.associateBy { it.serverName }
            assertEquals(cards.getValue("a").note, BroadcastStatus.Success, cards.getValue("a").status)
            assertTrue(cards.getValue("a").output, cards.getValue("a").output.contains("/home/a/conf/app.conf"))
            assertEquals("the older copy is replaced", CONTENT, String(a.files.getValue("/home/a/conf/app.conf")))
            assertEquals(BroadcastStatus.Failure, cards.getValue("b").status)
            assertTrue(cards.getValue("b").note.orEmpty(), cards.getValue("b").note.orEmpty().contains("/home/b"))
            assertEquals(BroadcastStatus.Failure, cards.getValue("c").status)
            assertTrue(cards.getValue("c").note.orEmpty(), cards.getValue("c").note.orEmpty().startsWith("Only"))
            assertNull("a short copy never takes the file's place", c.files["/home/c/conf/app.conf"])
            hosts.values.forEach { host -> assertTrue("no part file left: ${host.files.keys}", host.files.keys.none { "omniterm-part" in it }) }
            assertTrue("the phone keeps its copy for a retry", pick.local.exists())
            assertTrue(model.broadcastReport(), model.broadcastReport().startsWith("Push app.conf to ~/conf\n"))

            val summary = withTimeoutRun { repo.fleetRunsFlow.first { runs -> runs.any { it.run.pushedFile == "app.conf" } } }.single()
            assertEquals("~/conf", summary.run.command)
            assertEquals(FleetRunHistory.SOURCE_FLEET, summary.run.source)
            withContext(main) { model.loadFleetRunIntoBroadcast(summary.run, ids) }
            kotlinx.coroutines.delay(500)
            assertFalse("a push cannot be used again as a command", withContext(main) { model.broadcastCommandText } == "~/conf")

            // b can be read now, and c takes all of it: Retry pushes again to just those two.
            b.dirs += listOf("/home/b", "/home/b/conf")
            c.short = false
            val aBefore = a.files.getValue("/home/a/conf/app.conf")
            withContext(main) { model.retryFailedBroadcastHosts() }
            waitWhileOnMain(main, 10_000) { model.isBroadcastExecuting }
            assertTrue(model.broadcastResults.all { it.status == BroadcastStatus.Success })
            assertEquals(CONTENT, String(b.files.getValue("/home/b/conf/app.conf")))
            assertEquals(CONTENT, String(c.files.getValue("/home/c/conf/app.conf")))
            assertTrue("a was not pushed to again", aBefore === a.files.getValue("/home/a/conf/app.conf"))
            val retry = withTimeoutRun {
                repo.fleetRunsFlow.first { runs -> runs.any { it.run.source == FleetRunHistory.SOURCE_RETRY } }
            }.single { it.run.source == FleetRunHistory.SOURCE_RETRY }
            assertEquals("app.conf", retry.run.pushedFile)

            // Clearing the cards ends what a retry could need, and the phone's copy goes.
            withContext(main) { model.clearBroadcastOutputs() }
            waitWhileOnMain(main, 5_000) { pick.local.exists() }
        } finally {
            try {
                clearViewModelsAndAwaitTerminalJobs(store, main)
                withContext(Dispatchers.IO) { db.clearAllTables() }
            } finally {
                Dispatchers.resetMain()
                main.close()
            }
        }
    }

    private suspend fun <T> withTimeoutRun(block: suspend () -> T): T = kotlinx.coroutines.withTimeout(10_000) { block() }

    private companion object {
        const val CONTENT = "listen 8080\nworkers 4\n"
    }
}
