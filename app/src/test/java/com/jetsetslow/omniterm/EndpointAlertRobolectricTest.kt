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
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/** Checks the phone runs open incidents on their hosts, without the hosts' own metrics. */
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

    /**
     * A TCP Port rule for all hosts, given just a port, connects to each host's own address: the
     * host listening there stays quiet and the one refusing opens an incident.
     */
    @Test
    fun aTcpPortRuleOnAllHostsChecksEachHostsOwnAddress() = runBlocking {
        val listener = ServerSocket(0, 50, InetAddress.getByName("127.0.0.1"))
        // Accept and drop, so the backlog never fills while the checks repeat.
        val acceptor = Thread { while (!listener.isClosed) runCatching { listener.accept().close() } }.apply { isDaemon = true; start() }
        val main = Executors.newSingleThreadExecutor().asCoroutineDispatcher()
        Dispatchers.setMain(main)
        val store = ViewModelStore()
        try {
            val application = ApplicationProvider.getApplicationContext<Application>()
            val db = AppDatabase.getDatabase(application)
            withContext(Dispatchers.IO) { db.clearAllTables() }
            val repository = AppRepository(db)
            repository.insertServer(ServerEntity(name = "db", host = "127.0.0.1", port = 1, username = "deploy"))
            // The listener is bound to IPv4 only, so nothing answers on the IPv6 loopback: refused,
            // or unreachable on a machine without IPv6. Either way the port is not open there.
            repository.insertServer(ServerEntity(name = "gone", host = "::1", port = 1, username = "deploy"))
            val (up, gone) = repository.getAllServers().sortedBy { it.id }.let { it[0].id to it[1].id }
            val model = withContext(main) { AppViewModel(application, QuietHosts()) }
            store.put("test", model)

            withContext(main) {
                model.addAlertRule(0, EndpointChecks.TCP_PORT, "/", 1000f, "CRITICAL", "0m", target = listener.localPort.toString())
            }
            val alert = withTimeout(15_000) {
                while (repository.getActiveAlerts().isEmpty()) delay(100)
                repository.getActiveAlerts().single()
            }
            assertEquals(gone, alert.serverId)
            assertEquals(EndpointChecks.TCP_PORT, alert.metricName)
            assertEquals(EndpointChecks.URL_NO_RESPONSE, alert.currentValue)
            val ruleId = repository.getAllRules().single().id
            waitWhileOnMain(main, timeoutMillis = 15_000) {
                model.endpointCheckResults[ruleId to up] == null || model.endpointCheckResults[ruleId to gone] == null
            }
            val healthy = model.endpointCheckResults.getValue(ruleId to up)
            assertTrue("connected in ms", (healthy.value ?: -1f) >= 0f)
            assertEquals("127.0.0.1:${listener.localPort}", healthy.target)
            val refused = model.endpointCheckResults.getValue(ruleId to gone)
            assertEquals("[::1]:${listener.localPort}", refused.target)
            assertTrue(refused.summary, refused.summary.startsWith("not accepting connections"))
            assertEquals("the healthy host has no incident", listOf(gone), repository.getActiveAlerts().map { it.serverId })
        } finally {
            listener.close()
            acceptor.join(2_000)
            try {
                clearViewModelsAndAwaitTerminalJobs(store, main)
            } finally {
                Dispatchers.resetMain()
                main.close()
            }
        }
    }

    /**
     * A rule added while a round of checks runs is checked as soon as that round ends, not at the
     * next poll: the round read the rules before it was saved. A release build failed on the wait.
     */
    @Test
    fun aRuleAddedDuringARoundIsCheckedRightAfterIt() = runBlocking {
        val reached = CountDownLatch(1)
        val answer = CountDownLatch(1)
        val slow = HttpServer.create(InetSocketAddress(InetAddress.getLoopbackAddress(), 0), 0)
        slow.createContext("/") {
            reached.countDown()
            answer.await(10, TimeUnit.SECONDS)
            it.sendResponseHeaders(200, -1)
            it.close()
        }
        slow.start()
        val listener = ServerSocket(0, 50, InetAddress.getByName("127.0.0.1"))
        val acceptor = Thread { while (!listener.isClosed) runCatching { listener.accept().close() } }.apply { isDaemon = true; start() }
        val main = Executors.newSingleThreadExecutor().asCoroutineDispatcher()
        Dispatchers.setMain(main)
        val store = ViewModelStore()
        try {
            val application = ApplicationProvider.getApplicationContext<Application>()
            val db = AppDatabase.getDatabase(application)
            withContext(Dispatchers.IO) { db.clearAllTables() }
            val repository = AppRepository(db)
            repository.insertServer(ServerEntity(name = "web", host = "127.0.0.1", port = 1, username = "deploy"))
            val hostId = repository.getAllServers().single().id
            val model = withContext(main) { AppViewModel(application, QuietHosts()) }
            store.put("test", model)

            withContext(main) {
                model.addAlertRule(hostId, EndpointChecks.URL_CHECK, "/", 5000f, "CRITICAL", "0m", target = "http://127.0.0.1:${slow.address.port}/")
            }
            assertTrue("the round reached the slow site", withContext(Dispatchers.IO) { reached.await(10, TimeUnit.SECONDS) })
            withContext(main) {
                model.addAlertRule(hostId, EndpointChecks.TCP_PORT, "/", 1000f, "CRITICAL", "0m", target = listener.localPort.toString())
            }
            val tcpRule = withTimeout(5_000) {
                while (repository.getAllRules().size < 2) delay(10)
                repository.getAllRules().single { it.metricName == EndpointChecks.TCP_PORT }.id
            }
            // Let the new rule's own start request land while the round still waits on the site.
            delay(500)
            answer.countDown()

            // The next poll is 15 s away; the round queued behind the slow one checks it now.
            waitWhileOnMain(main, timeoutMillis = 5_000) { model.endpointCheckResults[tcpRule to hostId] == null }
            assertTrue("connected in ms", (model.endpointCheckResults.getValue(tcpRule to hostId).value ?: -1f) >= 0f)
        } finally {
            answer.countDown()
            slow.stop(0)
            listener.close()
            acceptor.join(2_000)
            try {
                clearViewModelsAndAwaitTerminalJobs(store, main)
            } finally {
                Dispatchers.resetMain()
                main.close()
            }
        }
    }
}
