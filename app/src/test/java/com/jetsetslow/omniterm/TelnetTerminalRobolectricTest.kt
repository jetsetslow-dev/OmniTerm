package com.jetsetslow.omniterm

import android.app.Application
import androidx.lifecycle.ViewModelStore
import androidx.test.core.app.ApplicationProvider
import com.jetsetslow.omniterm.data.AppDatabase
import com.jetsetslow.omniterm.data.AppRepository
import com.jetsetslow.omniterm.ui.AppViewModel
import com.jetsetslow.omniterm.ui.TerminalTransport
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.asCoroutineDispatcher
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
import java.net.InetAddress
import java.net.ServerSocket
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/** A Telnet connection from the Terminal: saved, shown, and kept on screen once the host hangs up. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
@OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)
class TelnetTerminalRobolectricTest {

    @Test
    fun aTelnetConnectionIsSavedOpensATerminalAndEndsWithItsReason() = runBlocking {
        val server = ServerSocket(0, 1, InetAddress.getLoopbackAddress())
        val hangUp = CountDownLatch(1)
        val host = Thread {
            server.accept().use { socket ->
                socket.getOutputStream().apply { write("switch> ".toByteArray()); flush() }
                hangUp.await(10, TimeUnit.SECONDS)
            }
        }.apply { start() }
        // Real time: AppViewModel deliberately does database work on Dispatchers.IO.
        val main = Executors.newSingleThreadExecutor().asCoroutineDispatcher()
        Dispatchers.setMain(main)
        val store = ViewModelStore()
        try {
            val application = ApplicationProvider.getApplicationContext<Application>()
            val db = AppDatabase.getDatabase(application)
            withContext(Dispatchers.IO) { db.clearAllTables() }
            val repository = AppRepository(db)
            val model = withContext(main) { AppViewModel(application, QuietHosts()) }
            store.put("test", model)

            var refused: String? = null
            withContext(main) {
                model.connectTelnet("core switch", "127.0.0.1", server.localPort, save = true) { refused = it }
            }
            waitWhileOnMain(main, 10_000) { model.activeSessions.none { it.transport == TerminalTransport.Telnet } }
            val shell = withContext(main) { model.activeSessions.single() }
            assertNull(refused)
            assertEquals("core switch", shell.serverName)
            waitWhileOnMain(main, 10_000) { model.terminalMatchesFor(shell, "switch>").isEmpty() }
            assertEquals(listOf("core switch" to server.localPort), repository.getAllTelnetHosts().map { it.name to it.port })

            hangUp.countDown()
            waitWhileOnMain(main, 10_000) { shell.endedBecause == null }
            assertEquals("Connection closed by the host", shell.endedBecause)
        } finally {
            hangUp.countDown()
            host.join(5_000)
            server.close()
            try {
                clearViewModelsAndAwaitTerminalJobs(store, main)
            } finally {
                Dispatchers.resetMain()
                main.close()
            }
        }
    }
}
