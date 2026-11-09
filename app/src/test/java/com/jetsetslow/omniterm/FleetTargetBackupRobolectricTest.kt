package com.jetsetslow.omniterm

import android.app.Application
import android.net.Uri
import androidx.lifecycle.ViewModelStore
import androidx.test.core.app.ApplicationProvider
import com.jetsetslow.omniterm.data.AppDatabase
import com.jetsetslow.omniterm.data.AppRepository
import com.jetsetslow.omniterm.data.FleetTargetSetEntity
import com.jetsetslow.omniterm.data.ServerEntity
import com.jetsetslow.omniterm.ui.AppViewModel
import com.jetsetslow.omniterm.ui.BackupFleetTargets
import com.jetsetslow.omniterm.ui.BackupSelection
import com.jetsetslow.omniterm.ui.FleetTargetMode
import com.jetsetslow.omniterm.ui.FleetTargets
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.asCoroutineDispatcher
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.setMain
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import org.json.JSONArray
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import java.io.ByteArrayOutputStream
import java.util.concurrent.Executors

/**
 * Host tags and saved Fleet targets travel with the hosts. Restored on another phone, a set of
 * picked hosts points at that phone's copies of them, and the phone's own set of a name is kept.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
@OptIn(ExperimentalCoroutinesApi::class)
class FleetTargetBackupRobolectricTest {
    @get:Rule val keyStore = TestAndroidKeyStore()

    @Test
    fun tagsAndSavedTargetsComeBackOnTheRestoredHosts() = runBlocking {
        val main = Executors.newSingleThreadExecutor().asCoroutineDispatcher()
        Dispatchers.setMain(main)
        val store = ViewModelStore()
        val application = ApplicationProvider.getApplicationContext<Application>()
        val db = AppDatabase.getDatabase(application)
        val repo = AppRepository(db)
        try {
            withContext(Dispatchers.IO) { db.clearAllTables() }
            val model = withContext(main) { AppViewModel(application) }
            store.put("backup", model)
            val nas = repo.insertServer(host("nas", "db, Prod")).toInt()
            val web = repo.insertServer(host("web", "prod")).toInt()
            repo.saveFleetTargetSet(FleetTargets(FleetTargetMode.Servers, serverIds = setOf(nas, web)).toSet("Pair"))
            repo.saveFleetTargetSet(FleetTargets(FleetTargetMode.Tags, tags = listOf("db", "prod"), allTags = true).toSet("Both"))
            repo.saveFleetTargetSet(FleetTargets(FleetTargetMode.Groups, groups = setOf("Rack 1")).toSet("Racks"))
            repo.saveFleetTargetSet(FleetTargets(FleetTargetMode.Tags, tags = listOf("prod")).toSet("Prod"))

            val uri = Uri.parse("content://backup-fixture/fleet-targets.json")
            val bytes = ByteArrayOutputStream()
            shadowOf(application.contentResolver).registerOutputStream(uri, bytes)
            val exported = CompletableDeferred<Pair<Boolean, String>>()
            withContext(main) { model.exportBackup(uri, PASSPHRASE, application, SELECTION) { ok, message -> exported.complete(ok to message) } }
            val (exportOk, exportMessage) = withTimeout(10_000) { exported.await() }
            assertTrue(exportMessage, exportOk)
            waitWhileOnMain(main) { model.backupExportRunning }
            val backup = bytes.toString(Charsets.UTF_8)

            // Another phone: it has web already (under another id) and its own "prod" set.
            withContext(Dispatchers.IO) { db.clearAllTables() }
            repo.insertServer(host("spare", ""))
            val webHere = repo.insertServer(host("web", "")).toInt()
            repo.saveFleetTargetSet(FleetTargets(FleetTargetMode.Groups, groups = setOf("Office")).toSet("prod"))
            val restored = CompletableDeferred<Pair<Boolean, String>>()
            withContext(main) { model.restoreEncryptedBackup(backup, PASSPHRASE, SELECTION) { ok, message -> restored.complete(ok to message) } }
            val (restoreOk, restoreMessage) = withTimeout(10_000) { restored.await() }
            assertTrue(restoreMessage, restoreOk)
            waitWhileOnMain(main) { model.backupRestoreRunning }

            val servers = repo.getAllServers().associateBy { it.name }
            assertEquals("a restored host keeps its tags", "db, Prod", servers.getValue("nas").tags)
            assertEquals("a host already here keeps its own", "", servers.getValue("web").tags)
            val sets = repo.fleetTargetSets().associate { it.name to FleetTargets.of(it) }
            assertEquals(setOf("Pair", "Both", "Racks", "prod"), sets.keys)
            assertEquals(
                "picked hosts point at this phone's copies",
                setOf(servers.getValue("nas").id, webHere),
                sets.getValue("Pair").serverIds,
            )
            assertTrue("the ids differ here, so the hosts were re-pointed", nas != servers.getValue("nas").id && web != webHere)
            assertEquals(FleetTargets(FleetTargetMode.Tags, tags = listOf("db", "prod"), allTags = true), sets.getValue("Both"))
            assertEquals(FleetTargets(FleetTargetMode.Groups, groups = setOf("Rack 1")), sets.getValue("Racks"))
            assertEquals("the phone's own set of a name wins", FleetTargets(FleetTargetMode.Groups, groups = setOf("Office")), sets.getValue("prod"))
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

    @Test
    fun aSetOfHostsLeftOutOfTheBackupIsDropped() {
        val sets = listOf(
            FleetTargets(FleetTargetMode.Servers, serverIds = setOf(1, 2)).toSet("Half"),
            FleetTargets(FleetTargetMode.Servers, serverIds = setOf(3)).toSet("Gone"),
            FleetTargets(FleetTargetMode.Tags, tags = listOf("prod")).toSet("Prod"),
            FleetTargetSetEntity(name = " ", mode = "Tags", tags = "[\"x\"]"),
        )
        val arr = BackupFleetTargets.json(sets, hostIds = setOf(1))
        assertEquals(2, arr.length())
        assertEquals("Half", arr.getJSONObject(0).getString("name"))
        assertEquals("[1]", arr.getJSONObject(0).getJSONArray("serverIds").toString())
        assertEquals("Prod", arr.getJSONObject(1).getString("name"))
    }

    @Test
    fun restoreSkipsUnknownEmptyAndRepeatedSets() {
        val arr = JSONArray(
            """
            [
              {"name": "Pair", "mode": "Servers", "serverIds": [7, 8, "9"]},
              {"name": "pair", "mode": "Tags", "tags": ["db"]},
              {"name": "Planets", "mode": "Planets", "tags": ["db"]},
              {"name": "Gone", "mode": "Servers", "serverIds": [99]},
              {"name": "Mine", "mode": "Groups", "groups": ["Rack"]},
              {"name": "Tags", "mode": "Tags", "tags": ["db", "DB", " "], "allTags": true},
              "not a set"
            ]
            """.trimIndent()
        )
        val sets = BackupFleetTargets.restore(arr, hostIdMap = mapOf(7 to 70, 8 to 80), keepNames = listOf(" MINE"))
        assertEquals(listOf("Pair", "Tags"), sets.map { it.name })
        assertEquals(setOf(70, 80), FleetTargets.of(sets[0]).serverIds)
        assertEquals(FleetTargets(FleetTargetMode.Tags, tags = listOf("db"), allTags = true), FleetTargets.of(sets[1]))
        assertEquals(emptyList<FleetTargetSetEntity>(), BackupFleetTargets.restore(null, emptyMap(), emptyList()))
    }

    private fun host(name: String, tags: String) = ServerEntity(
        name = name, host = "$name.lan", port = 22, username = "admin", authType = "password",
        authPassword = "pw-$name", tags = tags,
    )

    private companion object {
        const val PASSPHRASE = "fleet-target-passphrase"
        val SELECTION = BackupSelection.NONE.copy(servers = true)
    }
}
