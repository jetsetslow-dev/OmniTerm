package com.jetsetslow.omniterm

import android.app.Application
import androidx.lifecycle.ViewModelStore
import androidx.test.core.app.ApplicationProvider
import com.jetsetslow.omniterm.data.AppDatabase
import com.jetsetslow.omniterm.data.AppRepository
import com.jetsetslow.omniterm.data.RemoteCommands
import com.jetsetslow.omniterm.data.ServerEntity
import com.jetsetslow.omniterm.data.SimDockerImage
import com.jetsetslow.omniterm.data.SimDockerVolume
import com.jetsetslow.omniterm.data.ssh.SshCredentials
import com.jetsetslow.omniterm.data.ssh.SshTransport
import com.jetsetslow.omniterm.data.ssh.TerminalSession
import com.jetsetslow.omniterm.ui.AppViewModel
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.asCoroutineDispatcher
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.setMain
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.Executors

/**
 * The Containers tab's state belongs to the host it was made on.
 *
 * Users switch hosts often and do the same or different work on each, and the same names recur
 * across hosts: most have a volume called `data`, and a pulled image has the same id everywhere.
 * So a list, a pick or a batch made on one host must never act on another.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
@OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)
class ContainerHostScopeRobolectricTest {
    private val dataVolume = SimDockerVolume(name = "data", driver = "local", mountpoint = "/var/lib/docker/volumes/data")

    @Test
    fun oneHostsContainerListsAreClearedWhenAnotherIsSelected() = withHosts { model, transport, a, b ->
        transport.volumes = "docker\tdata\tlocal\t/var/lib/docker/volumes/data\t1.2GB\t0"
        withContext(main) { model.loadDocker() }
        waitWhileOnMain(main) { model.dockerLoading || model.dockerVolumes.isEmpty() }

        withContext(main) { model.selectedServerId = b }
        // Until b's own load lands, a's `data` volume sat under b's name beside a live Remove.
        assertTrue(model.dockerVolumes.isEmpty())
        assertTrue(model.dockerContainers.isEmpty() && model.dockerImages.isEmpty() && model.dockerNetworks.isEmpty())

        withContext(main) { model.selectedServerId = a }
        assertTrue("the lists are refetched, not kept", model.dockerVolumes.isEmpty())
    }

    @Test
    fun picksAndOpenStacksStayWithTheirHost() = withHosts { model, _, a, b ->
        withContext(main) {
            model.volumeSelection.toggleSelecting(a)
            model.volumeSelection.toggle(a, "docker:data")
            model.expandedStacks.toggle(a, "docker:web")

            model.selectedServerId = b
            assertFalse(model.volumeSelection.isSelecting(b))
            assertFalse(model.volumeSelection.isPicked(b, "docker:data"))
            assertFalse(model.expandedStacks.isPicked(b, "docker:web"))

            model.selectedServerId = a
            assertTrue(model.volumeSelection.isSelecting(a))
            assertEquals(setOf("docker:data"), model.volumeSelection.picked(a))
            assertTrue(model.expandedStacks.isPicked(a, "docker:web"))
        }
    }

    @Test
    fun aDeletedHostKeepsNothingPicked() = withHosts { model, _, a, _ ->
        withContext(main) {
            model.imageSelection.toggleSelecting(a)
            model.imageSelection.toggle(a, "docker:sha256:1")
            model.deleteServer(model.servers.value.single { it.id == a })
        }
        waitWhileOnMain(main) { model.servers.value.any { it.id == a } }
        waitWhileOnMain(main) { model.imageSelection.isSelecting(a) }
        assertTrue(model.imageSelection.picked(a).isEmpty())
    }

    @Test
    fun aBulkRemovalIsOneCommandOnTheHostItWasConfirmedFor() = withHosts { model, transport, a, b ->
        val hostA = model.servers.value.single { it.id == a }
        withContext(main) {
            model.volumeSelection.toggleSelecting(a)
            model.volumeSelection.toggle(a, "docker:data")
            // The user confirmed on a, then switched to b before the batch ran.
            model.selectedServerId = b
            model.removeDockerVolumes(listOf(dataVolume, dataVolume.copy(name = "db", runtime = "podman")), hostA)
        }
        withTimeout(5_000) { while (transport.streamed.isEmpty()) delay(10) }

        // One action per volume cancelled each other; all but the last could be dropped unrun.
        assertEquals(
            listOf("a.invalid" to "docker volume rm -f 'data' 2>&1; podman volume rm -f 'db' 2>&1"),
            transport.streamed.toList(),
        )
        assertFalse("a's batch has run, so its multi-select ends", model.volumeSelection.isSelecting(a))
    }

    @Test
    fun aBulkImageRemovalNamesEveryPickedImage() = withHosts { model, transport, a, _ ->
        val images = listOf("sha256:1", "sha256:2").map {
            SimDockerImage(id = it, repository = "nginx", tag = "latest", size = "", created = "")
        }
        withContext(main) { model.removeDockerImages(images, model.servers.value.single { it.id == a }) }
        withTimeout(5_000) { while (transport.streamed.isEmpty()) delay(10) }
        assertEquals(
            images.joinToString("; ") { RemoteCommands.dockerImageAction(it.id, "remove", it.runtime) },
            transport.streamed.single().second,
        )
    }

    private lateinit var main: CoroutineDispatcher

    private fun withHosts(body: suspend (AppViewModel, HostTransport, Int, Int) -> Unit) = runBlocking {
        // Real time: AppViewModel does its database work on Dispatchers.IO.
        val executor = Executors.newSingleThreadExecutor().asCoroutineDispatcher()
        main = executor
        Dispatchers.setMain(executor)
        val store = ViewModelStore()
        val transport = HostTransport()
        try {
            val application = ApplicationProvider.getApplicationContext<Application>()
            val repository = AppRepository(AppDatabase.getDatabase(application))
            val a = repository.insertServer(ServerEntity(name = "a", host = "a.invalid", username = "fixture")).toInt()
            val b = repository.insertServer(ServerEntity(name = "b", host = "b.invalid", username = "fixture")).toInt()
            val model = withContext(executor) { AppViewModel(application, transport) }
            store.put("test", model)
            waitWhileOnMain(main, 10_000) { model.servers.value.count { it.id == a || it.id == b } < 2 }
            withContext(executor) { model.selectedServerId = a }
            body(model, transport, a, b)
        } finally {
            try {
                clearViewModelsAndAwaitTerminalJobs(store, executor)
            } finally {
                Dispatchers.resetMain()
                executor.close()
            }
        }
    }

    /** Answers the container probes, and records each streamed action with the host it ran on. */
    private class HostTransport : SshTransport {
        @Volatile var volumes = ""
        val streamed = CopyOnWriteArrayList<Pair<String, String>>()

        override suspend fun exec(creds: SshCredentials, command: String, stdin: String?): String =
            if (command == RemoteCommands.DOCKER_VOLUMES) volumes else ""

        override suspend fun execStream(
            creds: SshCredentials,
            command: String,
            stdin: String?,
            onChunk: suspend (String) -> Unit,
        ): String {
            streamed.add(creds.host to command)
            return ""
        }

        override suspend fun testConnection(creds: SshCredentials): String? = null

        override suspend fun openShell(
            creds: SshCredentials,
            cols: Int,
            rows: Int,
            onPhaseChange: ((String) -> Unit)?,
        ): TerminalSession = IdleShell()
    }

    private class IdleShell : TerminalSession {
        override val output = MutableSharedFlow<ByteArray>(replay = 1)
        override val closed = MutableStateFlow(false)
        override val exitStatus = MutableStateFlow<Int?>(null)
        override val remoteExited = MutableStateFlow(false)
        override suspend fun write(bytes: ByteArray) = Unit
        override suspend fun resize(cols: Int, rows: Int) = Unit
        override fun close() { closed.value = true }
    }
}
