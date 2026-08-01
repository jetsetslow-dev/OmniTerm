package com.jetsetslow.omniterm.shared.feature

import com.jetsetslow.omniterm.shared.core.IdGenerator
import com.jetsetslow.omniterm.shared.core.OperationId
import com.jetsetslow.omniterm.shared.platform.ByteSink
import com.jetsetslow.omniterm.shared.platform.ByteSource
import com.jetsetslow.omniterm.shared.platform.CapabilityResult
import com.jetsetslow.omniterm.shared.platform.RemoteEntry
import com.jetsetslow.omniterm.shared.platform.SftpAdapter
import com.jetsetslow.omniterm.shared.platform.TransferProgress
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

private class RecordingSink : ByteSink {
    var closed = false
    val written = mutableListOf<Int>()
    override suspend fun write(buffer: ByteArray, count: Int) {
        written += count
    }

    override suspend fun close() {
        closed = true
    }
}

private class RecordingSource(private val total: Long) : ByteSource {
    var closed = false
    private var remaining = total
    override suspend fun read(buffer: ByteArray): Int {
        if (remaining <= 0) return -1
        val chunk = minOf(remaining, buffer.size.toLong()).toInt()
        remaining -= chunk
        return chunk
    }

    override suspend fun close() {
        closed = true
    }
}

private class MemoryLocalFiles(existing: Set<String> = emptySet()) : LocalFileGateway {
    val present = existing.toMutableSet()
    val discarded = mutableListOf<String>()
    val sinks = mutableMapOf<String, RecordingSink>()
    val sources = mutableMapOf<String, RecordingSource>()
    var sourceSize: Long? = 512

    override suspend fun exists(name: String): Boolean = name in present

    override suspend fun openSink(name: String, resolution: ConflictResolution): Pair<String, ByteSink> {
        val target = if (resolution == ConflictResolution.KeepBoth && name in present) "$name (1)" else name
        present += target
        val sink = RecordingSink()
        sinks[target] = sink
        return target to sink
    }

    override suspend fun openSource(name: String): Pair<ByteSource, Long?> {
        val source = RecordingSource(sourceSize ?: 0)
        sources[name] = source
        return source to sourceSize
    }

    override suspend fun discardPartial(name: String) {
        discarded += name
        present -= name
    }
}

private class FakeSftp(
    private var listing: List<RemoteEntry> = emptyList(),
) : SftpAdapter {
    var listGate: CompletableDeferred<Unit>? = null
    var listingsByPath: Map<String, List<RemoteEntry>> = emptyMap()
    var downloadGate: CompletableDeferred<Unit>? = null
    var downloadProgress: List<TransferProgress> = emptyList()
    var downloadResult: CapabilityResult<Unit> = CapabilityResult.Available(Unit)
    val cancelled = mutableListOf<OperationId>()

    override suspend fun list(path: String): CapabilityResult<List<RemoteEntry>> {
        listGate?.await()
        return CapabilityResult.Available(listingsByPath[path] ?: listing)
    }

    override suspend fun download(
        path: String,
        sink: ByteSink,
        progress: (TransferProgress) -> Unit,
    ): CapabilityResult<Unit> {
        downloadProgress.forEach(progress)
        downloadGate?.await()
        sink.write(ByteArray(8), 8)
        return downloadResult
    }

    override suspend fun upload(
        path: String,
        source: ByteSource,
        totalBytes: Long?,
        progress: (TransferProgress) -> Unit,
    ): CapabilityResult<Unit> {
        progress(TransferProgress(totalBytes ?: 0, totalBytes))
        return CapabilityResult.Available(Unit)
    }

    override fun cancel(operationId: OperationId) {
        cancelled += operationId
    }
}

private class TransferIds : IdGenerator {
    private var next = 0
    override fun nextId(): String = "t-${next++}"
}

private fun entry(path: String, directory: Boolean = false, size: Long = 0, modified: Long? = null) =
    RemoteEntry(path, directory, size, modified)

private class FakeRemoteFiles(var conflicts: List<RemoteConflict> = emptyList()) : RemoteFileGateway {
    var scans = 0
    var scanResult: CapabilityResult<List<RemoteConflict>>? = null
    var pasteResult: CapabilityResult<Unit> = CapabilityResult.Available(Unit)
    data class PasteCall(
        val destDir: String,
        val sources: List<String>,
        val move: Boolean,
        val skip: Set<String>,
        val keepBoth: Set<String>,
    )

    val pastes = mutableListOf<PasteCall>()

    override suspend fun scanConflicts(destDir: String, sources: List<String>): CapabilityResult<List<RemoteConflict>> {
        scans++
        return scanResult ?: CapabilityResult.Available(conflicts)
    }

    override suspend fun paste(
        destDir: String,
        sources: List<String>,
        move: Boolean,
        skip: Set<String>,
        keepBoth: Set<String>,
    ): CapabilityResult<Unit> {
        pastes += PasteCall(destDir, sources, move, skip, keepBoth)
        return pasteResult
    }
}

@OptIn(ExperimentalCoroutinesApi::class)
class FilesStoreTest {
    @Test
    fun sortingKeepsDirectoriesFirstInBothDirections() {
        val entries = listOf(
            entry("/srv/beta.txt", size = 30, modified = 300),
            entry("/srv/Alpha", directory = true, modified = 100),
            entry("/srv/alpha.txt", size = 10, modified = 200),
            entry("/srv/zeta", directory = true, modified = 400),
        )
        assertEquals(
            listOf("Alpha", "zeta", "alpha.txt", "beta.txt"),
            sortEntries(entries, FileSort.Name, ascending = true).map { fileName(it.path) },
        )
        assertEquals(
            listOf("zeta", "Alpha", "beta.txt", "alpha.txt"),
            sortEntries(entries, FileSort.Name, ascending = false).map { fileName(it.path) },
        )
        assertEquals(
            listOf("Alpha", "zeta", "beta.txt", "alpha.txt"),
            sortEntries(entries, FileSort.Size, ascending = false).map { fileName(it.path) },
        )
    }

    @Test
    fun parentPathStopsAtRoot() {
        assertEquals("/srv", parentPath("/srv/logs"))
        assertEquals("/", parentPath("/srv"))
        assertEquals("/", parentPath("/"))
        assertEquals("/", parentPath(""))
    }

    @Test
    fun switchingPathMidListingNeverPublishesStaleEntries() = runTest {
        val scope = CoroutineScope(StandardTestDispatcher(testScheduler))
        val sftp = FakeSftp()
        sftp.listingsByPath = mapOf(
            "/slow" to listOf(entry("/slow/old.txt")),
            "/fast" to listOf(entry("/fast/new.txt")),
        )
        val gate = CompletableDeferred<Unit>()
        sftp.listGate = gate
        val files = FilesStore(scope, sftp, MemoryLocalFiles(), TransferIds())

        files.dispatch(FilesAction.Navigate("/slow"))
        advanceUntilIdle()
        sftp.listGate = null
        files.dispatch(FilesAction.Navigate("/fast"))
        advanceUntilIdle()
        gate.complete(Unit)
        advanceUntilIdle()

        assertEquals("/fast", files.state.value.path)
        assertEquals(listOf("/fast/new.txt"), files.state.value.entries.map { it.path })
        files.close()
    }

    @Test
    fun downloadReportsDeterminateProgressAndCompletes() = runTest {
        val scope = CoroutineScope(StandardTestDispatcher(testScheduler))
        val sftp = FakeSftp(listOf(entry("/srv/app.log", size = 100)))
        sftp.downloadProgress = listOf(TransferProgress(50, 100))
        val local = MemoryLocalFiles()
        val files = FilesStore(scope, sftp, local, TransferIds())

        files.dispatch(FilesAction.Navigate("/srv"))
        advanceUntilIdle()
        files.dispatch(FilesAction.Download("/srv/app.log"))
        advanceUntilIdle()

        val transfer = files.state.value.transfers.single()
        assertEquals(TransferStatus.Completed, transfer.status)
        assertEquals(100L, transfer.completedBytes)
        assertEquals(1f, transfer.fraction)
        assertTrue(local.sinks.getValue("app.log").closed, "the destination stream must be closed")
        assertTrue(local.discarded.isEmpty(), "a completed download must not be discarded")
        files.close()
    }

    @Test
    fun transferWithUnknownSizeStaysIndeterminate() = runTest {
        val scope = CoroutineScope(StandardTestDispatcher(testScheduler))
        val sftp = FakeSftp()
        val gate = CompletableDeferred<Unit>()
        sftp.downloadGate = gate
        val files = FilesStore(scope, sftp, MemoryLocalFiles(), TransferIds())

        files.dispatch(FilesAction.Download("/srv/stream.bin"))
        advanceUntilIdle()

        val running = files.state.value.transfers.single()
        assertEquals(TransferStatus.Running, running.status)
        assertNull(running.fraction, "unknown size must not render as 0%")
        val aggregate = assertNotNull(files.state.value.aggregateProgress)
        assertNull(aggregate.fraction)
        gate.complete(Unit)
        advanceUntilIdle()
        files.close()
    }

    @Test
    fun cancellingADownloadClosesTheStreamAndRemovesThePartialFile() = runTest {
        val scope = CoroutineScope(StandardTestDispatcher(testScheduler))
        val sftp = FakeSftp()
        val gate = CompletableDeferred<Unit>()
        sftp.downloadGate = gate
        val local = MemoryLocalFiles()
        val files = FilesStore(scope, sftp, local, TransferIds())

        files.dispatch(FilesAction.Download("/srv/big.iso"))
        advanceUntilIdle()
        val id = files.state.value.transfers.single().id
        files.dispatch(FilesAction.CancelTransfer(id))
        advanceUntilIdle()

        assertEquals(TransferStatus.Cancelled, files.state.value.transfers.single().status)
        assertTrue(local.sinks.getValue("big.iso").closed)
        assertEquals(listOf("big.iso"), local.discarded)
        assertFalse("big.iso" in local.present)
        files.close()
    }

    @Test
    fun conflictDecisionKeepBothWritesToANewName() = runTest {
        val scope = CoroutineScope(StandardTestDispatcher(testScheduler))
        val local = MemoryLocalFiles(existing = setOf("notes.md"))
        val files = FilesStore(scope, FakeSftp(), local, TransferIds())

        files.dispatch(FilesAction.Download("/srv/notes.md"))
        advanceUntilIdle()

        val conflict = assertNotNull(files.state.value.pendingConflict)
        assertEquals("notes.md", conflict.localName)
        assertEquals(TransferStatus.AwaitingConflictDecision, files.state.value.transfers.single().status)

        files.dispatch(FilesAction.ResolveConflict(conflict.transferId, ConflictResolution.KeepBoth))
        advanceUntilIdle()

        val transfer = files.state.value.transfers.single()
        assertEquals(TransferStatus.Completed, transfer.status)
        assertEquals("notes.md (1)", transfer.localName)
        assertNull(files.state.value.pendingConflict)
        assertTrue(local.discarded.isEmpty())
        files.close()
    }

    @Test
    fun conflictDecisionSkipLeavesTheExistingFileUntouched() = runTest {
        val scope = CoroutineScope(StandardTestDispatcher(testScheduler))
        val local = MemoryLocalFiles(existing = setOf("notes.md"))
        val files = FilesStore(scope, FakeSftp(), local, TransferIds())

        files.dispatch(FilesAction.Download("/srv/notes.md"))
        advanceUntilIdle()
        val conflict = assertNotNull(files.state.value.pendingConflict)
        files.dispatch(FilesAction.ResolveConflict(conflict.transferId, ConflictResolution.Skip))
        advanceUntilIdle()

        assertEquals(TransferStatus.Cancelled, files.state.value.transfers.single().status)
        assertTrue(local.sinks.isEmpty(), "skip must not open the destination at all")
        assertTrue("notes.md" in local.present)
        files.close()
    }

    @Test
    fun uploadClosesItsSourceAndAggregatesProgress() = runTest {
        val scope = CoroutineScope(StandardTestDispatcher(testScheduler))
        val local = MemoryLocalFiles()
        local.sourceSize = 2_048
        val files = FilesStore(scope, FakeSftp(), local, TransferIds())

        files.dispatch(FilesAction.Upload("report.pdf", "/srv/report.pdf"))
        advanceUntilIdle()

        val transfer = files.state.value.transfers.single()
        assertEquals(TransferStatus.Completed, transfer.status)
        assertEquals(2_048L, transfer.totalBytes)
        assertTrue(local.sources.getValue("report.pdf").closed)
        assertNull(files.state.value.aggregateProgress, "no active transfers means no progress bar")
        files.close()
    }

    @Test
    fun aCleanPasteRunsServerSideWithoutStreamingBytes() = runTest {
        val scope = CoroutineScope(StandardTestDispatcher(testScheduler))
        val remote = FakeRemoteFiles()
        val local = MemoryLocalFiles()
        val files = FilesStore(scope, FakeSftp(), local, TransferIds(), remote)

        files.dispatch(FilesAction.Navigate("/dest"))
        advanceUntilIdle()
        files.dispatch(FilesAction.Copy(listOf("/src/a.txt", "/src/b.txt")))
        files.dispatch(FilesAction.BeginPaste)
        advanceUntilIdle()

        val call = remote.pastes.single()
        assertEquals("/dest", call.destDir)
        assertEquals(listOf("/src/a.txt", "/src/b.txt"), call.sources)
        assertFalse(call.move)
        assertTrue(call.skip.isEmpty() && call.keepBoth.isEmpty())
        assertEquals("Copied 2 item(s) here", files.state.value.status)
        // A successful paste consumes the clipboard, copies included.
        assertNull(files.state.value.clipboard)
        assertTrue(local.sinks.isEmpty(), "a same-host paste must not stream through the device")
        files.close()
    }

    @Test
    fun conflictsWaitForPerItemDecisionsAndSkippedNamesAreNeverIssued() = runTest {
        val scope = CoroutineScope(StandardTestDispatcher(testScheduler))
        val remote = FakeRemoteFiles(
            listOf(
                RemoteConflict("a.txt", ConflictVerdict.Different),
                RemoteConflict("b.txt", ConflictVerdict.Identical),
                RemoteConflict("c.txt", ConflictVerdict.Different),
            ),
        )
        val files = FilesStore(scope, FakeSftp(), MemoryLocalFiles(), TransferIds(), remote)

        files.dispatch(FilesAction.Navigate("/dest"))
        advanceUntilIdle()
        files.dispatch(FilesAction.Copy(listOf("/src/a.txt", "/src/b.txt", "/src/c.txt")))
        files.dispatch(FilesAction.BeginPaste)
        advanceUntilIdle()

        // Nothing is written until the user decides.
        assertTrue(remote.pastes.isEmpty())
        assertEquals(3, files.state.value.pasteConflicts.size)
        assertTrue(files.state.value.pasteConflicts.all { it.resolution == ConflictResolution.Overwrite })
        assertFalse(files.state.value.pasteUnverified)

        files.dispatch(FilesAction.SetConflictResolution("b.txt", ConflictResolution.Skip))
        files.dispatch(FilesAction.SetConflictResolution("c.txt", ConflictResolution.KeepBoth))
        files.dispatch(FilesAction.ConfirmPaste)
        advanceUntilIdle()

        val call = remote.pastes.single()
        assertEquals(setOf("b.txt"), call.skip)
        assertEquals(setOf("c.txt"), call.keepBoth)
        assertEquals("Copied 2 item(s) here", files.state.value.status)
        files.close()
    }

    @Test
    fun pastingIntoTheSourceFolderDefaultsToKeepBothOnCopyAndSkipOnMove() = runTest {
        val scope = CoroutineScope(StandardTestDispatcher(testScheduler))
        val remote = FakeRemoteFiles(listOf(RemoteConflict("a.txt", ConflictVerdict.Identical)))
        val files = FilesStore(scope, FakeSftp(), MemoryLocalFiles(), TransferIds(), remote)

        files.dispatch(FilesAction.Navigate("/src"))
        advanceUntilIdle()
        files.dispatch(FilesAction.Copy(listOf("/src/a.txt")))
        files.dispatch(FilesAction.BeginPaste)
        advanceUntilIdle()
        // Overwriting in place would issue a copy with identical source and destination, which fails.
        assertEquals(ConflictResolution.KeepBoth, files.state.value.pasteConflicts.single().resolution)

        files.dispatch(FilesAction.CancelPaste)
        files.dispatch(FilesAction.Cut(listOf("/src/a.txt")))
        files.dispatch(FilesAction.BeginPaste)
        advanceUntilIdle()
        assertEquals(ConflictResolution.Skip, files.state.value.pasteConflicts.single().resolution)

        files.dispatch(FilesAction.ConfirmPaste)
        advanceUntilIdle()
        assertEquals(setOf("a.txt"), remote.pastes.single().skip)
        assertEquals("Skipped all 1 item(s)", files.state.value.status)
        files.close()
    }

    @Test
    fun anUnverifiedComparisonIsFlaggedRatherThanImplyingCertainty() = runTest {
        val scope = CoroutineScope(StandardTestDispatcher(testScheduler))
        val remote = FakeRemoteFiles(listOf(RemoteConflict("a.txt", ConflictVerdict.Unknown)))
        val files = FilesStore(scope, FakeSftp(), MemoryLocalFiles(), TransferIds(), remote)

        files.dispatch(FilesAction.Navigate("/dest"))
        advanceUntilIdle()
        files.dispatch(FilesAction.Copy(listOf("/src/a.txt")))
        files.dispatch(FilesAction.BeginPaste)
        advanceUntilIdle()

        assertTrue(files.state.value.pasteUnverified)
        files.close()
    }

    @Test
    fun navigatingAwayAfterTheScanCancelsThePasteInsteadOfWritingElsewhere() = runTest {
        val scope = CoroutineScope(StandardTestDispatcher(testScheduler))
        val remote = FakeRemoteFiles(listOf(RemoteConflict("a.txt", ConflictVerdict.Different)))
        val files = FilesStore(scope, FakeSftp(), MemoryLocalFiles(), TransferIds(), remote)

        files.dispatch(FilesAction.Navigate("/dest"))
        advanceUntilIdle()
        files.dispatch(FilesAction.Copy(listOf("/src/a.txt")))
        files.dispatch(FilesAction.BeginPaste)
        advanceUntilIdle()

        files.dispatch(FilesAction.Navigate("/elsewhere"))
        advanceUntilIdle()
        files.dispatch(FilesAction.ConfirmPaste)
        advanceUntilIdle()

        assertTrue(remote.pastes.isEmpty(), "a stale destination must never be pasted into")
        assertEquals(
            "Paste cancelled because the clipboard, destination, host, or move mode changed.",
            files.state.value.error,
        )
        files.close()
    }

    @Test
    fun switchingHostAfterTheScanAlsoCancelsThePaste() = runTest {
        val scope = CoroutineScope(StandardTestDispatcher(testScheduler))
        val remote = FakeRemoteFiles(listOf(RemoteConflict("a.txt", ConflictVerdict.Different)))
        val files = FilesStore(scope, FakeSftp(), MemoryLocalFiles(), TransferIds(), remote)

        files.dispatch(FilesAction.SelectEndpoint("host-1"))
        files.dispatch(FilesAction.Navigate("/dest"))
        advanceUntilIdle()
        files.dispatch(FilesAction.Copy(listOf("/src/a.txt")))
        files.dispatch(FilesAction.BeginPaste)
        advanceUntilIdle()

        files.dispatch(FilesAction.SelectEndpoint("host-2"))
        files.dispatch(FilesAction.ConfirmPaste)
        advanceUntilIdle()

        assertTrue(remote.pastes.isEmpty())
        files.close()
    }

    @Test
    fun aFailedScanCancelsThePasteAndKeepsTheClipboard() = runTest {
        val scope = CoroutineScope(StandardTestDispatcher(testScheduler))
        val remote = FakeRemoteFiles()
        remote.scanResult = CapabilityResult.Failed(com.jetsetslow.omniterm.shared.platform.PlatformError.NetworkUnavailable)
        val files = FilesStore(scope, FakeSftp(), MemoryLocalFiles(), TransferIds(), remote)

        files.dispatch(FilesAction.Navigate("/dest"))
        advanceUntilIdle()
        files.dispatch(FilesAction.Copy(listOf("/src/a.txt")))
        files.dispatch(FilesAction.BeginPaste)
        advanceUntilIdle()

        assertTrue(remote.pastes.isEmpty())
        assertFalse(files.state.value.pasteScanning)
        assertEquals("Paste cancelled: conflict scan failed (Network unavailable)", files.state.value.error)
        // The clipboard survives a failed scan so the user can retry.
        assertNotNull(files.state.value.clipboard)
        files.close()
    }

    @Test
    fun aFailedPasteKeepsItsErrorThroughTheRefresh() = runTest {
        val scope = CoroutineScope(StandardTestDispatcher(testScheduler))
        val remote = FakeRemoteFiles()
        remote.pasteResult = CapabilityResult.Failed(com.jetsetslow.omniterm.shared.platform.PlatformError.PermissionDenied)
        val files = FilesStore(scope, FakeSftp(), MemoryLocalFiles(), TransferIds(), remote)

        files.dispatch(FilesAction.Navigate("/dest"))
        advanceUntilIdle()
        files.dispatch(FilesAction.Copy(listOf("/src/a.txt")))
        files.dispatch(FilesAction.BeginPaste)
        advanceUntilIdle()

        assertEquals("Paste failed: Permission denied", files.state.value.error)
        assertNotNull(files.state.value.clipboard, "a failed paste must not consume the clipboard")
        files.close()
    }

    @Test
    fun bookmarksToggleAndListingFailureIsObservable() = runTest {
        val scope = CoroutineScope(StandardTestDispatcher(testScheduler))
        val sftp = object : SftpAdapter {
            override suspend fun list(path: String) =
                CapabilityResult.Failed(com.jetsetslow.omniterm.shared.platform.PlatformError.PermissionDenied)

            override suspend fun download(path: String, sink: ByteSink, progress: (TransferProgress) -> Unit) =
                CapabilityResult.Available(Unit)

            override suspend fun upload(
                path: String,
                source: ByteSource,
                totalBytes: Long?,
                progress: (TransferProgress) -> Unit,
            ) = CapabilityResult.Available(Unit)

            override fun cancel(operationId: OperationId) = Unit
        }
        val files = FilesStore(scope, sftp, MemoryLocalFiles(), TransferIds())

        files.dispatch(FilesAction.Navigate("/root"))
        advanceUntilIdle()
        assertEquals("Permission denied", files.state.value.error)
        assertFalse(files.state.value.loading)

        files.dispatch(FilesAction.ToggleBookmark("/root"))
        assertEquals(listOf("/root"), files.state.value.bookmarks)
        files.dispatch(FilesAction.ToggleBookmark("/root"))
        assertTrue(files.state.value.bookmarks.isEmpty())
        files.close()
    }
}
