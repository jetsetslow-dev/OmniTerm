package com.jetsetslow.omniterm

import android.app.Application
import androidx.lifecycle.ViewModelStore
import androidx.test.core.app.ApplicationProvider
import com.google.common.truth.Truth.assertThat
import com.jetsetslow.omniterm.data.AppDatabase
import com.jetsetslow.omniterm.data.AppRepository
import com.jetsetslow.omniterm.data.ServerEntity
import com.jetsetslow.omniterm.data.ssh.JschSftp
import com.jetsetslow.omniterm.ui.AppViewModel
import io.mockk.coEvery
import io.mockk.coVerify
import io.mockk.mockkConstructor
import io.mockk.unmockkConstructor
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.asCoroutineDispatcher
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.setMain
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import java.util.concurrent.Executors

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
@OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)
class SftpNewFileRobolectricTest {
    @Test
    fun changingHostDuringCreateDoesNotReadOrOpenAFileOnTheNewHost() = withModel { model, repository, main ->
        val first = repository.insertServer(ServerEntity(name = "Original", host = "127.0.0.1", port = 1, username = "fixture")).toInt()
        val second = repository.insertServer(ServerEntity(name = "Other", host = "127.0.0.2", port = 1, username = "fixture")).toInt()
        waitWhileOnMain(main, 10_000) { model.servers.value.size < 2 }
        val started = CompletableDeferred<Unit>()
        val finish = CompletableDeferred<Unit>()
        coEvery { anyConstructed<JschSftp>().createFile(any()) } coAnswers {
            started.complete(Unit)
            finish.await()
        }
        coEvery { anyConstructed<JschSftp>().list(any()) } returns emptyList()
        coEvery { anyConstructed<JschSftp>().readText(any(), any()) } returns "other host's text"
        withContext(main) {
            model.selectedServerId = first
            model.loadSftp("/original")
        }.join()
        withContext(main) { model.sftpNewFile("notes.txt") }
        withTimeout(10_000) { started.await() }
        withContext(main) { assertThat(model.sftpFileCreation).contains("Original") }
        withContext(main) {
            model.selectedServerId = second
            model.loadSftp("/other")
        }.join()
        finish.complete(Unit)
        waitWhileOnMain(main, 10_000) { model.sftpFileCreation != null }
        coVerify(exactly = 1) { anyConstructed<JschSftp>().createFile("/original/notes.txt") }
        coVerify(exactly = 1) { anyConstructed<JschSftp>().list("/other") }
        coVerify(exactly = 0) { anyConstructed<JschSftp>().readText(any(), any()) }
        withContext(main) {
            assertThat(model.edittingSftpFile).isNull()
            assertThat(model.sftpPath).isEqualTo("/other")
            assertThat(model.sftpStatus).contains("Original")
        }
    }

    @Test
    fun noSelectedHostReportsAnErrorInsteadOfCreatingNothingSuccessfully() = withModel { model, _, main ->
        withContext(main) { model.sftpNewFile("notes.txt") }
        waitWhileOnMain(main, 10_000) { model.sftpError == null && model.sftpStatus == null }
        withContext(main) {
            assertThat(model.sftpError).contains("host")
            assertThat(model.sftpStatus).isNull()
        }
        coVerify(exactly = 0) { anyConstructed<JschSftp>().createFile(any()) }
    }

    private fun withModel(block: suspend (AppViewModel, AppRepository, kotlinx.coroutines.ExecutorCoroutineDispatcher) -> Unit) = runBlocking {
        val main = Executors.newSingleThreadExecutor().asCoroutineDispatcher()
        Dispatchers.setMain(main)
        val store = ViewModelStore()
        mockkConstructor(JschSftp::class)
        try {
            val application = ApplicationProvider.getApplicationContext<Application>()
            val db = AppDatabase.getDatabase(application)
            withContext(Dispatchers.IO) { db.clearAllTables() }
            val repository = AppRepository(db)
            val model = withContext(main) { AppViewModel(application, QuietHosts()) }
            store.put("test", model)
            block(model, repository, main)
        } finally {
            try {
                clearViewModelsAndAwaitTerminalJobs(store, main)
            } finally {
                unmockkConstructor(JschSftp::class)
                Dispatchers.resetMain()
                main.close()
            }
        }
    }
}
