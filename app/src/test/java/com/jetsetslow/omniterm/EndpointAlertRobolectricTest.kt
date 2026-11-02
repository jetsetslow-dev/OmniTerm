package com.jetsetslow.omniterm

import android.app.Application
import androidx.lifecycle.ViewModelStore
import androidx.test.core.app.ApplicationProvider
import com.jetsetslow.omniterm.data.AppDatabase
import com.jetsetslow.omniterm.data.AppRepository
import com.jetsetslow.omniterm.data.EndpointChecks
import com.jetsetslow.omniterm.data.ServerEntity
import com.jetsetslow.omniterm.ui.AppViewModel
import com.sun.net.httpserver.HttpServer
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.asCoroutineDispatcher
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.setMain
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertEquals
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import java.net.InetAddress
import java.net.InetSocketAddress
import java.util.concurrent.Executors

/** A URL check the phone runs opens an incident on its host, without the host's own metrics. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
@OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)
class EndpointAlertRobolectricTest {

    @Test
    fun aFailingUrlCheckOpensAnIncidentOnItsHost() = runBlocking {
        val site = HttpServer.create(InetSocketAddress(InetAddress.getLoopbackAddress(), 0), 0)
        site.createContext("/") { it.sendResponseHeaders(503, -1); it.close() }
        site.start()
        // Real time: AppViewModel deliberately does database work on Dispatchers.IO.
        val main = Executors.newSingleThreadExecutor().asCoroutineDispatcher()
        Dispatchers.setMain(main)
        val store = ViewModelStore()
        try {
            val application = ApplicationProvider.getApplicationContext<Application>()
            val db = AppDatabase.getDatabase(application)
            withContext(Dispatchers.IO) { db.clearAllTables() }
            val repository = AppRepository(db)
            // Port 1 on this machine refuses at once: the host has no metrics, only the check.
            repository.insertServer(ServerEntity(name = "web", host = "127.0.0.1", port = 1, username = "deploy"))
            val hostId = repository.getAllServers().single().id
            val model = withContext(main) { AppViewModel(application, QuietHosts()) }
            store.put("test", model)

            val url = "http://127.0.0.1:${site.address.port}/health"
            withContext(main) {
                model.addAlertRule(hostId, EndpointChecks.URL_CHECK, "/", 2000f, "CRITICAL", "0m", target = url)
            }

            val alert = withTimeout(15_000) {
                while (repository.getActiveAlerts().isEmpty()) delay(100)
                repository.getActiveAlerts().single()
            }
            assertEquals(hostId, alert.serverId)
            assertEquals(EndpointChecks.URL_CHECK, alert.metricName)
            assertEquals("the HTTP status, as a failure", -503f, alert.currentValue)
            val ruleId = repository.getAllRules().single().id
            assertEquals("HTTP 503: Service Unavailable", model.endpointCheckResults.getValue(ruleId to hostId).summary)
        } finally {
            site.stop(0)
            try {
                clearViewModelsAndAwaitTerminalJobs(store, main)
            } finally {
                Dispatchers.resetMain()
                main.close()
            }
        }
    }
}
