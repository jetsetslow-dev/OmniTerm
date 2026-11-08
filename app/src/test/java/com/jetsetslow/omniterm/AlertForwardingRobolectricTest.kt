package com.jetsetslow.omniterm

import android.app.Application
import androidx.lifecycle.ViewModelStore
import androidx.test.core.app.ApplicationProvider
import com.jetsetslow.omniterm.data.AlertForwarding
import com.jetsetslow.omniterm.data.AppDatabase
import com.jetsetslow.omniterm.data.AppRepository
import com.jetsetslow.omniterm.data.HostChecks
import com.jetsetslow.omniterm.data.ServerEntity
import com.jetsetslow.omniterm.data.ssh.SshCredentials
import com.jetsetslow.omniterm.data.ssh.SshTransport
import com.jetsetslow.omniterm.data.ssh.TerminalSession
import com.jetsetslow.omniterm.ui.AppViewModel
import com.sun.net.httpserver.HttpServer
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
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import java.net.InetAddress
import java.net.InetSocketAddress
import java.util.concurrent.Executors
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit

/** Forwarded alerts follow the incident: one when it opens, one when it recovers, none while muted or off. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
@OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)
class AlertForwardingRobolectricTest {

    @Test
    fun aWebhookHearsAnIncidentOpenAndRecover() = withModel { repository, model, hostId, host ->
        withContext(main) {
            model.saveAlertForwarding(AlertForwarding.Config(AlertForwarding.KIND_WEBHOOK, url = hookUrl))
            model.addAlertRule(hostId, HostChecks.HOST_OFFLINE, "/", 0f, "CRITICAL", "0m")
        }
        refreshUntil(model, hostId) { repository.getActiveAlerts().isNotEmpty() }
        val opened = posts.poll(10, TimeUnit.SECONDS)
        assertNotNull("the opening incident was forwarded", opened)
        for (part in listOf(""""event":"triggered"""", """"severity":"CRITICAL"""", """"host":"Lab"""", """"rule":"Host Offline"""", """"message":"Not reachable over SSH"""")) {
            assertTrue(opened, opened!!.contains(part))
        }
        waitWhileOnMain(main) { model.alertForwardStatus?.second?.ok != true }

        host.up = true
        refreshUntil(model, hostId) { repository.getActiveAlerts().isEmpty() }
        val recovered = posts.poll(10, TimeUnit.SECONDS)
        assertNotNull("the recovery was forwarded", recovered)
        assertTrue(recovered, recovered!!.contains(""""event":"resolved""""))
        assertTrue(recovered, recovered.contains(""""title":"Resolved: Lab""""))
        assertNull("one message each way", posts.poll(1, TimeUnit.SECONDS))
    }

    @Test
    fun aMutedIncidentRecoversQuietly() = withModel { repository, model, hostId, host ->
        withContext(main) {
            model.saveAlertForwarding(AlertForwarding.Config(AlertForwarding.KIND_WEBHOOK, url = hookUrl))
            model.addAlertRule(hostId, HostChecks.HOST_OFFLINE, "/", 0f, "CRITICAL", "0m")
        }
        refreshUntil(model, hostId) { repository.getActiveAlerts().isNotEmpty() }
        assertNotNull(posts.poll(10, TimeUnit.SECONDS))
        val alert = repository.getActiveAlerts().single()
        withContext(main) { model.muteAlertForOneHour(alert.id) }
        withTimeout(5_000) {
            while (repository.getActiveAlerts().single().mutedUntil <= System.currentTimeMillis()) delay(50)
        }

        host.up = true
        refreshUntil(model, hostId) { repository.getActiveAlerts().isEmpty() }
        assertNull("a muted incident's recovery is not forwarded", posts.poll(2, TimeUnit.SECONDS))
    }

    @Test
    fun nothingIsForwardedWhileForwardingIsOff() = withModel { repository, model, hostId, _ ->
        withContext(main) {
            // Turned off with the address still filled in: the address alone must not send.
            model.saveAlertForwarding(AlertForwarding.Config(AlertForwarding.KIND_OFF, url = hookUrl))
            model.addAlertRule(hostId, HostChecks.HOST_OFFLINE, "/", 0f, "CRITICAL", "0m")
        }
        refreshUntil(model, hostId) { repository.getActiveAlerts().isNotEmpty() }
        assertNull(posts.poll(2, TimeUnit.SECONDS))
        assertEquals(null, withContext(main) { model.alertForwardStatus })
    }

    private lateinit var main: ExecutorCoroutineDispatcher
    private lateinit var hookUrl: String
    private val posts = LinkedBlockingQueue<String>()

    private suspend fun refreshUntil(model: AppViewModel, hostId: Int, done: suspend () -> Boolean) {
        withTimeout(20_000) {
            while (!done()) {
                withContext(main) { model.refreshServer(hostId) }
                delay(200)
            }
        }
    }

    private fun withModel(body: suspend (AppRepository, AppViewModel, Int, SwitchableHost) -> Unit) = runBlocking {
        val hook = HttpServer.create(InetSocketAddress(InetAddress.getLoopbackAddress(), 0), 0)
        hook.createContext("/hook") { ex ->
            posts.add(ex.requestBody.readBytes().toString(Charsets.UTF_8))
            ex.sendResponseHeaders(204, -1)
            ex.close()
        }
        hook.start()
        hookUrl = "http://127.0.0.1:${hook.address.port}/hook"
        // Real time: AppViewModel deliberately does database work on Dispatchers.IO.
        main = Executors.newSingleThreadExecutor().asCoroutineDispatcher()
        Dispatchers.setMain(main)
        val store = ViewModelStore()
        try {
            val application = ApplicationProvider.getApplicationContext<Application>()
            val db = AppDatabase.getDatabase(application)
            withContext(Dispatchers.IO) { db.clearAllTables() }
            val repository = AppRepository(db)
            // .invalid never resolves, so the direct port probe fails and the SSH route is tried.
            val hostId = repository.insertServer(ServerEntity(name = "Lab", host = "lab.invalid", username = "fixture")).toInt()
            val host = SwitchableHost()
            val model = withContext(main) { AppViewModel(application, host) }
            store.put("test", model)
            body(repository, model, hostId, host)
        } finally {
            hook.stop(0)
            try {
                clearViewModelsAndAwaitTerminalJobs(store, main)
            } finally {
                Dispatchers.resetMain()
                main.close()
            }
        }
    }

    /** A Linux host that cannot be reached until [up], then answers with healthy metrics. */
    private class SwitchableHost : SshTransport {
        @Volatile var up = false

        override suspend fun exec(creds: SshCredentials, command: String, stdin: String?): String = when {
            !up -> "SSH Error: connect timed out"
            "echo '@MEM'" in command -> "@OS\nLinux\n@CPU\n100.0 id\n@MEM\nMem: 100 20 0 0 0 80\n@DISK\n/dev/root 100 10 90 10% /\n"
            else -> "Linux\n/bin/bash\n"
        }

        override suspend fun execStream(
            creds: SshCredentials,
            command: String,
            stdin: String?,
            onChunk: suspend (String) -> Unit,
        ): String = exec(creds, command, stdin)

        override suspend fun testConnection(creds: SshCredentials): String? = if (up) null else "connect timed out"

        override suspend fun openShell(
            creds: SshCredentials,
            cols: Int,
            rows: Int,
            onPhaseChange: ((String) -> Unit)?,
        ): TerminalSession = error("No shell is opened in these tests")
    }
}
