package com.jetsetslow.omniterm

import android.app.Application
import androidx.lifecycle.ViewModelStore
import androidx.test.core.app.ApplicationProvider
import com.jetsetslow.omniterm.data.AppDatabase
import com.jetsetslow.omniterm.data.AppRepository
import com.jetsetslow.omniterm.data.TunnelKinds
import com.jetsetslow.omniterm.data.tunnel.CloudflareAccessSettings
import com.jetsetslow.omniterm.data.tunnel.TunnelEngine
import com.jetsetslow.omniterm.data.tunnel.TunnelManager
import com.jetsetslow.omniterm.data.tunnel.TunnelNode
import com.jetsetslow.omniterm.data.tunnel.RunningTunnel
import com.jetsetslow.omniterm.ui.AppViewModel
import java.util.concurrent.Executors
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.asCoroutineDispatcher
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.test.setMain
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
@OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)
class CloudflareAccessRobolectricTest {
    @get:Rule val keys = TestAndroidKeyStore()

    @Test fun jsonKeepsBothTokenFieldsAndNormalizesTheHostname() {
        val settings = CloudflareAccessSettings(" SSH.Example.com ", "fixture-id", "fixture-secret")
        assertEquals(settings.copy(hostname = "ssh.example.com"), CloudflareAccessSettings.parse(settings.toConfig()))
        assertNull(CloudflareAccessSettings.parse("invalid"))
        assertNull(CloudflareAccessSettings.parse("{}"))
    }

    @Test fun saveEditAndTestKeepSecretsEncryptedAndOffTheEditor() = runBlocking {
        val main = Executors.newSingleThreadExecutor().asCoroutineDispatcher()
        Dispatchers.setMain(main)
        val store = ViewModelStore()
        val app = ApplicationProvider.getApplicationContext<Application>()
        val db = AppDatabase.getDatabase(app)
        val repo = AppRepository(db)
        val previous = TunnelManager.engine
        var checks = 0
        TunnelManager.engine = object : TunnelEngine {
            override fun check(kind: String, config: String): String? {
                assertEquals(TunnelKinds.CLOUDFLARE_ACCESS, kind)
                assertEquals("fixture-secret", CloudflareAccessSettings.parse(config)!!.clientSecret)
                checks++
                return null
            }
            override fun start(kind: String, config: String, resolve: (String) -> List<String>, node: TunnelNode): RunningTunnel = error("Saving must never contact Cloudflare")
        }
        try {
            withContext(Dispatchers.IO) { db.clearAllTables() }
            val vm = withContext(main) { AppViewModel(app) }.also { store.put("access", it) }
            val original = CloudflareAccessSettings("ssh.example.com", "fixture-id", "fixture-secret")
            suspend fun save(id: Int?, settings: CloudflareAccessSettings) {
                val result = CompletableDeferred<String?>()
                withContext(main) { vm.saveAccessTunnel(id, "Access", settings, listOf("Home")) { result.complete(it) } }
                assertNull(withTimeout(10_000) { result.await() })
            }
            save(null, original)
            val tunnel = repo.getAllTunnels().single()
            assertEquals(TunnelKinds.CLOUDFLARE_ACCESS, tunnel.kind)
            assertFalse(db.tunnelDao().get(tunnel.id)!!.config.contains("fixture-secret"))
            assertEquals("", repo.tunnelsFlow.first().single().config)
            val loaded = CompletableDeferred<CloudflareAccessSettings?>()
            withContext(main) { vm.loadAccessSettings(tunnel.id) { loaded.complete(it) } }
            val editor = withTimeout(10_000) { loaded.await() }!!
            assertEquals(original.forEditor(), editor)
            assertEquals(original, CloudflareAccessSettings.parse(vm.accessConfig(tunnel.id, editor)))
            save(tunnel.id, editor.copy(clientId = "new-id"))
            assertEquals(original.copy(clientId = "new-id"), CloudflareAccessSettings.parse(repo.getTunnel(tunnel.id)!!.config))
            assertEquals(2, checks)
        } finally {
            clearViewModelsAndAwaitTerminalJobs(store, main)
            withContext(Dispatchers.IO) { db.clearAllTables() }
            TunnelManager.engine = previous
            Dispatchers.resetMain()
            main.close()
        }
    }
}
