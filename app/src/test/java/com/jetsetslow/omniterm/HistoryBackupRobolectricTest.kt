package com.jetsetslow.omniterm

import android.app.Application
import android.net.Uri
import androidx.lifecycle.ViewModelStore
import androidx.test.core.app.ApplicationProvider
import com.jetsetslow.omniterm.data.AppDatabase
import com.jetsetslow.omniterm.data.AppRepository
import com.jetsetslow.omniterm.data.Automation
import com.jetsetslow.omniterm.data.AutomationGrantEntity
import com.jetsetslow.omniterm.data.FleetRunEntity
import com.jetsetslow.omniterm.data.FleetRunHistory
import com.jetsetslow.omniterm.data.McpCallEntity
import com.jetsetslow.omniterm.data.McpCallOutcome
import com.jetsetslow.omniterm.data.MetricHistoryEntity
import com.jetsetslow.omniterm.data.PersistentSessionEntity
import com.jetsetslow.omniterm.data.QuickScriptEntity
import com.jetsetslow.omniterm.data.ServerEntity
import com.jetsetslow.omniterm.data.StackRegistryEntity
import com.jetsetslow.omniterm.data.mcp.McpSettings
import com.jetsetslow.omniterm.ui.AppViewModel
import com.jetsetslow.omniterm.ui.BackupContents
import com.jetsetslow.omniterm.ui.BackupHistory
import com.jetsetslow.omniterm.ui.BackupSelection
import com.jetsetslow.omniterm.ui.backupTooLargeToRestore
import com.jetsetslow.omniterm.ui.hashPinForStorage
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.asCoroutineDispatcher
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.setMain
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
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
 * A backup carries the history and device state too: Fleet runs, monitoring history, tmux
 * sessions, Compose stacks and the AI assistant log. Restored on another phone, each follows its
 * host there; what the phone already has stays, and restoring twice adds nothing. Automation, the
 * AI assistant and App Lock come back too, but switched off, and never taking a lock away.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
@OptIn(ExperimentalCoroutinesApi::class)
class HistoryBackupRobolectricTest {
    @get:Rule val keyStore = TestAndroidKeyStore()

    private val application = ApplicationProvider.getApplicationContext<Application>()

    @Test
    fun historyFollowsItsHostsToAnotherPhoneAndIsNotAddedTwice() = withModel { model, main, repo, db ->
        val minute = System.currentTimeMillis() / 60_000 * 60_000 - 3 * 60 * 60_000L
        val web = repo.insertServer(host("web")).toInt()
        val dbHost = repo.insertServer(host("db")).toInt()
        repo.recordFleetRun(
            FleetRunEntity(runKey = "run-1", startedAt = minute, finishedAt = minute + 5_000, command = "uptime"),
            listOf(
                FleetRunHistory.host(web, "web", "Success", null, "up 3 days", false),
                FleetRunHistory.host(dbHost, "db", "Success", null, "up 9 days", false),
                // A host deleted since: the run still names it.
                FleetRunHistory.host(999, "retired", "Failure", "SSH Error", "", false),
            ),
        )
        repo.recordFleetRun(FleetRunEntity(runKey = "run-2", startedAt = minute + 60_000, finishedAt = minute + 61_000, command = "df -h"), emptyList())
        repo.upsertPersistentSession(PersistentSessionEntity(tmuxName = "omniterm-abc", serverId = web, serverName = "web", createdAt = minute))
        repo.upsertStacks(listOf(StackRegistryEntity(serverId = dbHost, runtime = "docker", project = "media", workingDir = "/srv/media", configFiles = "/srv/media/compose.yml", lastSeenAt = minute)))
        // Two samples in one minute become their average; the next minute is a point of its own.
        repo.insertMetric(sample(web, minute, cpu = 10f))
        repo.insertMetric(sample(web, minute + 15_000, cpu = 30f))
        repo.insertMetric(sample(web, minute + 60_000, cpu = 50f))
        repo.insertMetric(sample(dbHost, minute, cpu = 1f))
        repo.insertMetric(sample(dbHost, minute + 60_000, cpu = 2f))
        repo.insertMetric(sample(dbHost, minute + 120_000, cpu = 3f))
        repo.recordMcpCall(McpCallEntity(at = minute, client = "Claude", tool = "list_hosts", outcome = McpCallOutcome.OK, detail = "2 hosts"))
        repo.recordMcpCall(McpCallEntity(at = minute + 1, client = "Claude", tool = "run_command", outcome = McpCallOutcome.REFUSED, detail = "not allowed"))

        val backup = export(model, main, BackupSelection())
        assertTrue("Fleet output is sensitive, so the backup is encrypted", JSONObject(backup).has("data"))
        val contents = inspect(model, main, backup)
        assertEquals(2, contents.fleetRuns)
        assertEquals("web's two minutes and db's three", 5, contents.monitoringPoints)
        assertEquals(1, contents.tmuxSessions)
        assertEquals(1, contents.composeStacks)
        assertEquals(2, contents.assistantCalls)

        // Another phone, which has db already, with its own history for its middle minute, and
        // run-2 in its own Fleet history.
        withContext(Dispatchers.IO) { db.clearAllTables() }
        val dbHere = repo.insertServer(host("db")).toInt()
        repo.insertMetric(sample(dbHere, minute + 60_000, cpu = 77f))
        repo.recordFleetRun(FleetRunEntity(runKey = "run-2", startedAt = minute + 60_000, finishedAt = minute + 61_000, command = "df -h"), emptyList())

        val message = restore(model, main, backup, BackupSelection())
        val webHere = repo.getAllServers().single { it.name == "web" }.id
        assertTrue(message, "2 Fleet run(s)" !in message && "1 Fleet run(s)" in message)

        val runs = repo.fleetRunsForBackup().associate { (run, hosts) -> run.runKey to hosts }
        assertEquals(setOf("run-1", "run-2"), runs.keys)
        val hosts = runs.getValue("run-1").associateBy { it.serverName }
        assertEquals(webHere, hosts.getValue("web").serverId)
        assertEquals(dbHere, hosts.getValue("db").serverId)
        assertTrue("a host not on this phone matches none of its hosts", hosts.getValue("retired").serverId < 0)
        assertEquals("up 3 days", hosts.getValue("web").output)

        assertEquals(listOf(webHere to "omniterm-abc"), repo.getPersistentSessions().map { it.serverId to it.tmuxName })
        waitWhileOnMain(main) { model.restorablePersistentSessions.isEmpty() }
        assertEquals("media", repo.getAllStacks().single { it.serverId == dbHere }.project)

        val webPoints = repo.getMetricsForServer(webHere)
        assertEquals(listOf(minute to 20f, minute + 60_000 to 50f), webPoints.map { it.timestamp to it.cpuUsage })
        val dbPoints = repo.getMetricsForServer(dbHere)
        assertEquals("only before and after this phone's own history", listOf(1f, 77f, 3f), dbPoints.map { it.cpuUsage })

        assertEquals(setOf("list_hosts", "run_command"), repo.getMcpCalls().map { it.tool }.toSet())

        // The same backup again changes nothing.
        restore(model, main, backup, BackupSelection())
        assertEquals(2, repo.fleetRunsForBackup().size)
        assertEquals(1, repo.getPersistentSessions().size)
        assertEquals(1, repo.getAllStacks().size)
        assertEquals(2, repo.getMetricsForServer(webHere).size)
        assertEquals(3, repo.getMetricsForServer(dbHere).size)
        assertEquals(2, repo.getMcpCalls().size)
    }

    @Test
    fun untickedHistoryIsNeitherSavedNorRestored() = withModel { model, main, repo, db ->
        val minute = System.currentTimeMillis() / 60_000 * 60_000 - 60 * 60_000L
        val web = repo.insertServer(host("web")).toInt()
        repo.recordFleetRun(FleetRunEntity(runKey = "run-1", startedAt = minute, finishedAt = minute, command = "uptime"), emptyList())
        repo.insertMetric(sample(web, minute, cpu = 10f))
        repo.recordMcpCall(McpCallEntity(at = minute, client = "Claude", tool = "list_hosts", outcome = McpCallOutcome.OK, detail = ""))

        val none = BackupSelection(fleetHistory = false, monitoringHistory = false, assistantLog = false)
        val withoutHistory = inspect(model, main, export(model, main, none))
        assertEquals(BackupContents(), withoutHistory.copy(servers = 0, settings = 0, alertRules = 0, scripts = 0))

        val backup = export(model, main, BackupSelection())
        withContext(Dispatchers.IO) { db.clearAllTables() }
        restore(model, main, backup, none)
        assertEquals(emptyList<Any>(), repo.fleetRunsForBackup())
        assertEquals(emptyList<Any>(), repo.getMetricsForServer(repo.getAllServers().single().id))
        assertEquals(emptyList<Any>(), repo.getMcpCalls())
    }

    @Test
    fun automationAndTheAssistantComeBackPointedAtTheNewHostsAndSwitchedOff() = withModel { model, main, repo, db ->
        val web = repo.insertServer(host("web")).toInt()
        val nas = repo.insertServer(host("nas")).toInt()
        repo.insertScript(QuickScriptEntity(emoji = "", name = "Restart media", command = "systemctl restart jellyfin", color = "cyan", category = "Media"))
        val script = repo.getAllScripts().single { it.name == "Restart media" }.id
        val token = Automation.hash("omt_tasker-token-for-the-test")
        repo.insertAutomationGrant(
            AutomationGrantEntity(scriptId = script, serverIds = Automation.joinServerIds(listOf(web, nas)), tokenHash = token, label = "Tasker", createdAt = 1_000L),
        )
        repo.insertSetting(Automation.SETTING_ENABLED, "true")
        val assistantToken = Automation.hash("omt_assistant-token-for-the-test")
        repo.insertSetting(McpSettings.ENABLED, "true")
        repo.insertSetting(McpSettings.TOKEN_HASH, assistantToken)
        repo.insertSetting(McpSettings.HOSTS, web.toString())
        repo.insertSetting(McpSettings.ANY_COMMAND, "true")
        repo.insertSetting(McpSettings.PORT, "47900")
        repo.insertSetting(McpSettings.TUNNEL_HOST, nas.toString())
        repo.insertSetting(McpSettings.TUNNEL_PORT, "8022")

        val backup = export(model, main, BackupSelection())
        val contents = inspect(model, main, backup)
        assertEquals(1, contents.automationGrants)
        assertEquals(1, contents.assistantSettings)

        // Another phone, whose hosts have other ids, with automation and its own assistant on.
        withContext(Dispatchers.IO) { db.clearAllTables() }
        repo.insertServer(host("spare"))
        repo.insertSetting(Automation.SETTING_ENABLED, "true")
        repo.insertSetting(McpSettings.ENABLED, "true")
        repo.insertSetting(McpSettings.TOKEN_HASH, Automation.hash("omt_this-phones-own-token-x"))

        val message = restore(model, main, backup, BackupSelection())
        assertTrue(message, "Automation and the AI assistant are off until you turn them on in Tools." in message)
        val servers = repo.getAllServers().associate { it.name to it.id }
        val grant = repo.getAutomationGrants().single()
        assertEquals(repo.getAllScripts().single { it.name == "Restart media" }.id, grant.scriptId)
        assertEquals(Automation.joinServerIds(listOf(servers.getValue("web"), servers.getValue("nas"))), grant.serverIds)
        assertEquals("a token Tasker already holds works again", token, grant.tokenHash)
        assertEquals("false", repo.getSetting(Automation.SETTING_ENABLED))
        assertEquals("false", repo.getSetting(McpSettings.ENABLED))
        assertEquals(assistantToken, repo.getSetting(McpSettings.TOKEN_HASH))
        assertEquals(servers.getValue("web").toString(), repo.getSetting(McpSettings.HOSTS))
        assertEquals(servers.getValue("nas").toString(), repo.getSetting(McpSettings.TUNNEL_HOST))
        assertEquals("8022", repo.getSetting(McpSettings.TUNNEL_PORT))
        assertEquals("47900", repo.getSetting(McpSettings.PORT))
        assertEquals("true", repo.getSetting(McpSettings.ANY_COMMAND))

        // Twice changes nothing; unticked, nothing comes back.
        restore(model, main, backup, BackupSelection())
        assertEquals(1, repo.getAutomationGrants().size)
        withContext(Dispatchers.IO) { db.clearAllTables() }
        restore(model, main, backup, BackupSelection(automation = false))
        assertEquals(emptyList<Any>(), repo.getAutomationGrants())
        assertNull(repo.getSetting(McpSettings.TOKEN_HASH))
    }

    @Test
    fun appLockComesBackOnlyToLockAndBiometricsStayWithEachPhone() = withModel { model, main, repo, db ->
        repo.insertServer(host("web"))
        val pin = hashPinForStorage("2468")
        repo.insertSetting("app_pin", pin)
        repo.insertSetting("app_lock_enabled", "true")
        repo.insertSetting("app_lock_grace_ms", "60000")
        repo.insertSetting("biometrics_enabled", "true")
        repo.insertSetting("pin_failed_attempts", "3")
        val locked = export(model, main, BackupSelection())
        withContext(Dispatchers.IO) { db.clearAllTables() }
        repo.insertServer(host("web"))
        // As App Lock's switch leaves it when turned off: the PIN kept, the lock off.
        repo.insertSetting("app_pin", hashPinForStorage("1357"))
        repo.insertSetting("app_lock_enabled", "false")
        val unlocked = export(model, main, BackupSelection())

        // An unlocked phone takes the backup's lock, but not its fingerprint unlock or failed attempts.
        withContext(Dispatchers.IO) { db.clearAllTables() }
        val message = restore(model, main, locked, BackupSelection())
        assertTrue(message, "App Lock now asks for the backup's PIN." in message)
        assertEquals(pin, repo.getSetting("app_pin"))
        assertEquals("true", repo.getSetting("app_lock_enabled"))
        assertEquals("60000", repo.getSetting("app_lock_grace_ms"))
        assertNull(repo.getSetting("biometrics_enabled"))
        assertNull(repo.getSetting("pin_failed_attempts"))

        // A backup made with App Lock off leaves this phone's lock on.
        val again = restore(model, main, unlocked, BackupSelection())
        assertFalse(again, "App Lock" in again)
        assertEquals(pin, repo.getSetting("app_pin"))
        assertEquals("true", repo.getSetting("app_lock_enabled"))
    }

    @Test
    fun monitoringIsSavedPerHostAndDaySoNoArrayIsTooLongForAnOlderApp() {
        val day = 24 * 60 * 60_000L
        val points = (0 until 3 * 1440).map { sample(serverId = 4, time = 10 * day + it * 60_000L, cpu = 12.345f) }
        val json = BackupHistory.monitoringJson(points, 60_000L)
        assertEquals(3, json.length())
        assertEquals(1440, json.getJSONObject(0).getJSONArray("points").length())
        assertEquals("a tenth is kept, not a float's noise", "12.3", json.getJSONObject(0).getJSONArray("points").getJSONArray(0).get(1).toString())

        val read = BackupHistory.monitoringFrom(json).getValue(4)
        assertEquals(points.size, read.size)
        assertNull(read.first().cpuTemperatureC)

        // A point that makes no sense is skipped, not a failed restore.
        val hostile = JSONArray().put(
            JSONObject().put("serverId", 4).put(
                "points",
                JSONArray().put(JSONArray().put(0).put(1)).put("text").put(JSONArray().put(day).put("x").put(1).put(1).put(1).put(1).put(1)),
            ),
        ).put(JSONObject().put("serverId", -1).put("points", JSONArray()))
        assertEquals(emptyMap<Int, List<MetricHistoryEntity>>(), BackupHistory.monitoringFrom(hostile))
    }

    @Test
    fun monitoringUsesTheFinestStepThatFits() = runBlocking {
        val asked = mutableListOf<Long>()
        val step = BackupHistory.monitoringStep { stepMs ->
            asked += stepMs
            if (stepMs < 15 * 60_000L) BackupHistory.MONITORING_MAX_POINTS + 1 else BackupHistory.MONITORING_MAX_POINTS
        }
        assertEquals(15 * 60_000L, step)
        assertEquals(listOf(60_000L, 5 * 60_000L, 15 * 60_000L), asked)
        assertEquals("hourly when nothing fits", 60 * 60_000L, BackupHistory.monitoringStep { Int.MAX_VALUE })
    }

    @Test
    fun aBackupARestoreCouldNotReadIsRefused() {
        val json = "{\"servers\":[]}"
        assertNull(backupTooLargeToRestore(json, json, encrypted = false, maxInputChars = 100))
        val tooLong = backupTooLargeToRestore(json, "x".repeat(101), encrypted = false, maxInputChars = 100)
        assertTrue(tooLong, tooLong!!.contains("Untick Monitoring history or Fleet history"))

        val envelope = { dataChars: Int -> JSONObject().put("data", "A".repeat(dataChars)).toString() }
        assertNull(backupTooLargeToRestore(json, envelope(16), encrypted = true, maxInputChars = 1_000, maxPlainBytes = 100, maxCiphertextBytes = 12))
        assertTrue(backupTooLargeToRestore("x".repeat(101), envelope(16), encrypted = true, maxInputChars = 1_000, maxPlainBytes = 100, maxCiphertextBytes = 12) != null)
        assertTrue(backupTooLargeToRestore(json, envelope(20), encrypted = true, maxInputChars = 1_000, maxPlainBytes = 100, maxCiphertextBytes = 12) != null)
    }

    private suspend fun export(model: AppViewModel, main: CoroutineDispatcher, selection: BackupSelection): String {
        val uri = Uri.parse("content://backup-fixture/history-${System.nanoTime()}.json")
        val bytes = ByteArrayOutputStream()
        shadowOf(application.contentResolver).registerOutputStream(uri, bytes)
        val done = CompletableDeferred<Pair<Boolean, String>>()
        withContext(main) { model.exportBackup(uri, PASSPHRASE, application, selection) { ok, message -> done.complete(ok to message) } }
        val (ok, message) = withTimeout(20_000) { done.await() }
        assertTrue(message, ok)
        waitWhileOnMain(main) { model.backupExportRunning }
        return bytes.toString(Charsets.UTF_8)
    }

    private suspend fun inspect(model: AppViewModel, main: CoroutineDispatcher, backup: String): BackupContents {
        val done = CompletableDeferred<BackupContents?>()
        withContext(main) { model.inspectBackupContents(backup, PASSPHRASE) { _, contents, _ -> done.complete(contents) } }
        return checkNotNull(withTimeout(20_000) { done.await() })
    }

    private suspend fun restore(model: AppViewModel, main: CoroutineDispatcher, backup: String, selection: BackupSelection): String {
        val done = CompletableDeferred<Pair<Boolean, String>>()
        withContext(main) { model.restoreEncryptedBackup(backup, PASSPHRASE, selection) { ok, message -> done.complete(ok to message) } }
        val (ok, message) = withTimeout(20_000) { done.await() }
        assertTrue(message, ok)
        waitWhileOnMain(main) { model.backupRestoreRunning }
        return message
    }

    private fun withModel(block: suspend (AppViewModel, CoroutineDispatcher, AppRepository, AppDatabase) -> Unit) = runBlocking {
        val main = Executors.newSingleThreadExecutor().asCoroutineDispatcher()
        Dispatchers.setMain(main)
        val store = ViewModelStore()
        val db = AppDatabase.getDatabase(application)
        try {
            withContext(Dispatchers.IO) { db.clearAllTables() }
            val model = withContext(main) { AppViewModel(application) }
            store.put("backup", model)
            block(model, main, AppRepository(db), db)
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

    private fun host(name: String) = ServerEntity(
        name = name, host = "$name.lan", port = 22, username = "admin", authType = "password", authPassword = "pw-$name",
    )

    private fun sample(serverId: Int, time: Long, cpu: Float) = MetricHistoryEntity(
        serverId = serverId, timestamp = time, cpuUsage = cpu, ramUsage = 40f, diskUsage = 50f,
        latency = 12, networkIn = 1f, networkOut = 2f,
    )

    private companion object {
        const val PASSPHRASE = "history-backup-passphrase"
    }
}
