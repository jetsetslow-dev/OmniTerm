package com.jetsetslow.omniterm.shared.feature

import com.jetsetslow.omniterm.shared.core.IdGenerator
import com.jetsetslow.omniterm.shared.core.OperationGeneration
import com.jetsetslow.omniterm.shared.platform.ByteSink
import com.jetsetslow.omniterm.shared.platform.ByteSource
import com.jetsetslow.omniterm.shared.platform.CapabilityResult
import com.jetsetslow.omniterm.shared.platform.PlatformError
import com.jetsetslow.omniterm.shared.platform.RemoteEntry
import com.jetsetslow.omniterm.shared.platform.SftpAdapter
import com.jetsetslow.omniterm.shared.platform.TransferProgress
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

enum class FileSort { Name, Size, Modified }

enum class TransferDirection { Download, Upload }

enum class TransferStatus { Queued, AwaitingConflictDecision, Running, Completed, Cancelled, Failed }

/** What to do when a download's destination name is already taken. */
enum class ConflictResolution { Overwrite, KeepBoth, Skip }

data class TransferItem(
    val id: String,
    val direction: TransferDirection,
    val remotePath: String,
    val localName: String,
    val status: TransferStatus,
    val completedBytes: Long = 0,
    val totalBytes: Long? = null,
    val error: String? = null,
) {
    /** Null means "running, size unknown" — the UI must show an indeterminate indicator, not 0%. */
    val fraction: Float?
        get() = totalBytes?.takeIf { it > 0 }?.let { (completedBytes.toDouble() / it).coerceIn(0.0, 1.0).toFloat() }

    val active: Boolean
        get() = status == TransferStatus.Queued || status == TransferStatus.Running ||
            status == TransferStatus.AwaitingConflictDecision
}

data class TransferConflict(val transferId: String, val localName: String)

data class FilesState(
    val path: String = "/",
    val entries: List<RemoteEntry> = emptyList(),
    val sort: FileSort = FileSort.Name,
    val ascending: Boolean = true,
    val loading: Boolean = false,
    val progress: OperationProgress? = null,
    val error: String? = null,
    val bookmarks: List<String> = emptyList(),
    val transfers: List<TransferItem> = emptyList(),
    val pendingConflict: TransferConflict? = null,
) {
    val activeTransfers: List<TransferItem> get() = transfers.filter { it.active }

    /**
     * Aggregate progress over active transfers. It is determinate only when *every* active transfer
     * knows its size; otherwise the total would jump around as unknown sizes resolve.
     */
    val aggregateProgress: OperationProgress?
        get() {
            val active = activeTransfers
            if (active.isEmpty()) return null
            val message = if (active.size == 1) "Transferring ${active.first().localName}" else "Transferring ${active.size} files"
            val totals = active.map { it.totalBytes }
            return if (totals.all { it != null }) {
                OperationProgress(message, active.sumOf { it.completedBytes }, totals.filterNotNull().sum())
            } else {
                OperationProgress(message)
            }
        }
}

sealed interface FilesAction {
    data class Navigate(val path: String) : FilesAction
    data object NavigateUp : FilesAction
    data object Refresh : FilesAction
    data object CancelLoad : FilesAction
    data class SetSort(val sort: FileSort, val ascending: Boolean) : FilesAction
    data class ToggleBookmark(val path: String) : FilesAction
    data class Download(val remotePath: String) : FilesAction
    data class Upload(val localName: String, val remotePath: String) : FilesAction
    data class ResolveConflict(val transferId: String, val resolution: ConflictResolution) : FilesAction
    data class CancelTransfer(val transferId: String) : FilesAction
}

/**
 * Local-side file access for transfers. Every platform implements it with its own sandbox rules;
 * the store only ever sees names and streams.
 */
interface LocalFileGateway {
    suspend fun exists(name: String): Boolean

    /**
     * Opens the destination and returns the name actually used: [ConflictResolution.KeepBoth] must
     * return a *different*, unused name. Implementations that promise atomic replacement should
     * stage the write and swap on close, so [discardPartial] of a failed overwrite cannot destroy
     * the file that was already there.
     */
    suspend fun openSink(name: String, resolution: ConflictResolution): Pair<String, ByteSink>
    suspend fun openSource(name: String): Pair<ByteSource, Long?>

    /** Deletes a partially written file so a cancelled transfer never looks complete. */
    suspend fun discardPartial(name: String)
}

/** Portable path helpers; remote paths are POSIX regardless of the client platform. */
internal fun parentPath(path: String): String {
    val trimmed = path.trimEnd('/')
    if (trimmed.isEmpty() || trimmed == "/") return "/"
    val cut = trimmed.lastIndexOf('/')
    return if (cut <= 0) "/" else trimmed.substring(0, cut)
}

internal fun fileName(path: String): String = path.trimEnd('/').substringAfterLast('/').ifEmpty { "/" }

internal fun sortEntries(entries: List<RemoteEntry>, sort: FileSort, ascending: Boolean): List<RemoteEntry> {
    // Directories always lead: a size or date sort that interleaves them makes a listing unusable.
    val comparator = when (sort) {
        FileSort.Name -> compareBy<RemoteEntry> { fileName(it.path).lowercase() }
        FileSort.Size -> compareBy<RemoteEntry> { it.size }
        FileSort.Modified -> compareBy<RemoteEntry> { it.modifiedEpochMillis ?: Long.MIN_VALUE }
    }
    val directed = if (ascending) comparator else comparator.reversed()
    return entries.sortedWith(compareByDescending<RemoteEntry> { it.directory }.then(directed))
}

/**
 * Portable files/transfers orchestration (IOS-032): directory navigation and sorting, bookmarks,
 * and a transfer queue with determinate-or-explicitly-indeterminate progress, conflict decisions,
 * and cancellation that closes streams and removes partial files.
 */
class FilesStore(
    private val scope: CoroutineScope,
    private val sftp: SftpAdapter,
    private val local: LocalFileGateway,
    private val ids: IdGenerator,
) : FeatureStore<FilesState, FilesAction> {
    private val mutableState = MutableStateFlow(FilesState())
    override val state: StateFlow<FilesState> = mutableState.asStateFlow()
    private val mutableEffects = MutableSharedFlow<StoreEffect>(extraBufferCapacity = 8)
    override val effects: SharedFlow<StoreEffect> = mutableEffects.asSharedFlow()

    private val listingGeneration = OperationGeneration()
    private var listingJob: Job? = null
    private val transferJobs = mutableMapOf<String, Job>()
    private val conflictDecisions = mutableMapOf<String, CompletableDeferred<ConflictResolution>>()

    override fun dispatch(action: FilesAction) {
        when (action) {
            is FilesAction.Navigate -> load(action.path)
            FilesAction.NavigateUp -> load(parentPath(mutableState.value.path))
            FilesAction.Refresh -> load(mutableState.value.path)
            FilesAction.CancelLoad -> cancelLoad()
            is FilesAction.SetSort -> mutableState.update {
                it.copy(sort = action.sort, ascending = action.ascending, entries = sortEntries(it.entries, action.sort, action.ascending))
            }
            is FilesAction.ToggleBookmark -> mutableState.update {
                it.copy(
                    bookmarks = if (action.path in it.bookmarks) it.bookmarks - action.path else it.bookmarks + action.path,
                )
            }
            is FilesAction.Download -> enqueueDownload(action.remotePath)
            is FilesAction.Upload -> enqueueUpload(action.localName, action.remotePath)
            is FilesAction.ResolveConflict -> conflictDecisions.remove(action.transferId)?.complete(action.resolution)
            is FilesAction.CancelTransfer -> cancelTransfer(action.transferId)
        }
    }

    // ── Listing ──

    private fun load(path: String) {
        listingJob?.cancel()
        val owner = listingGeneration.next()
        mutableState.update { it.copy(path = path, loading = true, error = null, progress = OperationProgress("Listing $path")) }
        listingJob = scope.launch {
            when (val result = sftp.list(path)) {
                is CapabilityResult.Available -> publish(owner, path) { current ->
                    current.copy(
                        entries = sortEntries(result.value, current.sort, current.ascending),
                        loading = false,
                        progress = null,
                        error = null,
                    )
                }
                is CapabilityResult.Unsupported -> publish(owner, path) {
                    it.copy(loading = false, progress = null, error = result.reason)
                }
                is CapabilityResult.Failed -> publish(owner, path) {
                    it.copy(loading = false, progress = null, error = describe(result.error))
                }
            }
        }
    }

    /**
     * Applies a listing result only when it is still the newest one *and* the user has not moved to
     * another path. Either check alone lets a slow listing repopulate the wrong directory.
     */
    private fun publish(owner: Long, path: String, transform: (FilesState) -> FilesState) {
        if (!listingGeneration.isCurrent(owner)) return
        mutableState.update { if (it.path == path) transform(it) else it }
    }

    private fun cancelLoad() {
        listingGeneration.invalidate()
        listingJob?.cancel()
        listingJob = null
        mutableState.update { it.copy(loading = false, progress = null) }
    }

    // ── Transfers ──

    private fun enqueueDownload(remotePath: String) {
        val item = TransferItem(
            id = ids.nextId(),
            direction = TransferDirection.Download,
            remotePath = remotePath,
            localName = fileName(remotePath),
            status = TransferStatus.Queued,
            totalBytes = mutableState.value.entries.firstOrNull { it.path == remotePath }?.size,
        )
        mutableState.update { it.copy(transfers = it.transfers + item) }
        transferJobs[item.id] = scope.launch { runDownload(item) }
    }

    private suspend fun runDownload(item: TransferItem) {
        var name = item.localName
        var sink: ByteSink? = null
        var completed = false
        // Only a destination this transfer actually opened may be discarded. Skipping a conflict
        // must leave the user's existing file exactly where it was.
        var ownedDestination: String? = null
        try {
            if (local.exists(name)) {
                val resolution = awaitConflictDecision(item)
                if (resolution == ConflictResolution.Skip) {
                    updateTransfer(item.id) { it.copy(status = TransferStatus.Cancelled) }
                    return
                }
                val opened = local.openSink(name, resolution)
                name = opened.first
                sink = opened.second
            } else {
                val opened = local.openSink(name, ConflictResolution.Overwrite)
                name = opened.first
                sink = opened.second
            }
            ownedDestination = name
            updateTransfer(item.id) { it.copy(status = TransferStatus.Running, localName = name) }
            val result = sftp.download(item.remotePath, sink) { progress -> reportProgress(item.id, progress) }
            when (result) {
                is CapabilityResult.Available -> {
                    completed = true
                    updateTransfer(item.id) {
                        it.copy(status = TransferStatus.Completed, completedBytes = it.totalBytes ?: it.completedBytes)
                    }
                }
                is CapabilityResult.Unsupported -> updateTransfer(item.id) {
                    it.copy(status = TransferStatus.Failed, error = result.reason)
                }
                is CapabilityResult.Failed -> updateTransfer(item.id) {
                    it.copy(status = TransferStatus.Failed, error = describe(result.error))
                }
            }
        } catch (cancellation: CancellationException) {
            markCancelled(item.id)
            throw cancellation
        } catch (error: Throwable) {
            updateTransfer(item.id) { it.copy(status = TransferStatus.Failed, error = "Transfer failed") }
        } finally {
            // NonCancellable: cleanup must still run when the job was cancelled, or a half-written
            // file would remain and read as a complete download.
            withContext(NonCancellable) {
                runCatching { sink?.close() }
                if (!completed) ownedDestination?.let { runCatching { local.discardPartial(it) } }
                conflictDecisions.remove(item.id)
                transferJobs.remove(item.id)
                clearConflictPrompt(item.id)
            }
        }
    }

    private fun enqueueUpload(localName: String, remotePath: String) {
        val item = TransferItem(
            id = ids.nextId(),
            direction = TransferDirection.Upload,
            remotePath = remotePath,
            localName = localName,
            status = TransferStatus.Queued,
        )
        mutableState.update { it.copy(transfers = it.transfers + item) }
        transferJobs[item.id] = scope.launch { runUpload(item) }
    }

    private suspend fun runUpload(item: TransferItem) {
        var source: ByteSource? = null
        try {
            val opened = local.openSource(item.localName)
            source = opened.first
            val total = opened.second
            updateTransfer(item.id) { it.copy(status = TransferStatus.Running, totalBytes = total) }
            when (val result = sftp.upload(item.remotePath, source, total) { progress -> reportProgress(item.id, progress) }) {
                is CapabilityResult.Available -> updateTransfer(item.id) {
                    it.copy(status = TransferStatus.Completed, completedBytes = it.totalBytes ?: it.completedBytes)
                }
                is CapabilityResult.Unsupported -> updateTransfer(item.id) {
                    it.copy(status = TransferStatus.Failed, error = result.reason)
                }
                is CapabilityResult.Failed -> updateTransfer(item.id) {
                    it.copy(status = TransferStatus.Failed, error = describe(result.error))
                }
            }
        } catch (cancellation: CancellationException) {
            markCancelled(item.id)
            throw cancellation
        } catch (error: Throwable) {
            updateTransfer(item.id) { it.copy(status = TransferStatus.Failed, error = "Transfer failed") }
        } finally {
            withContext(NonCancellable) {
                runCatching { source?.close() }
                transferJobs.remove(item.id)
            }
        }
    }

    private suspend fun awaitConflictDecision(item: TransferItem): ConflictResolution {
        val decision = CompletableDeferred<ConflictResolution>()
        conflictDecisions[item.id] = decision
        updateTransfer(item.id) { it.copy(status = TransferStatus.AwaitingConflictDecision) }
        mutableState.update { it.copy(pendingConflict = TransferConflict(item.id, item.localName)) }
        return decision.await()
    }

    private fun clearConflictPrompt(transferId: String) {
        mutableState.update { if (it.pendingConflict?.transferId == transferId) it.copy(pendingConflict = null) else it }
    }

    private fun reportProgress(transferId: String, progress: TransferProgress) {
        updateTransfer(transferId) {
            if (it.status != TransferStatus.Running) it
            else it.copy(completedBytes = progress.completedBytes, totalBytes = progress.totalBytes ?: it.totalBytes)
        }
    }

    private fun cancelTransfer(transferId: String) {
        conflictDecisions.remove(transferId)?.complete(ConflictResolution.Skip)
        transferJobs.remove(transferId)?.cancel()
        markCancelled(transferId)
        clearConflictPrompt(transferId)
    }

    private fun markCancelled(transferId: String) {
        updateTransfer(transferId) {
            if (it.status == TransferStatus.Completed || it.status == TransferStatus.Failed) it
            else it.copy(status = TransferStatus.Cancelled)
        }
    }

    private fun updateTransfer(transferId: String, transform: (TransferItem) -> TransferItem) {
        mutableState.update { current ->
            current.copy(transfers = current.transfers.map { if (it.id == transferId) transform(it) else it })
        }
    }

    private fun describe(error: PlatformError): String = when (error) {
        PlatformError.Cancelled -> "Cancelled"
        PlatformError.PermissionDenied -> "Permission denied"
        PlatformError.AuthenticationFailed -> "Authentication failed"
        PlatformError.NetworkUnavailable -> "Network unavailable"
        PlatformError.HostKeyRejected -> "Host key rejected"
        PlatformError.NotFound -> "Not found"
        PlatformError.StorageUnavailable -> "Storage unavailable"
        is PlatformError.Protocol -> "Transfer failed (${error.code})"
    }

    override fun close() {
        cancelLoad()
        conflictDecisions.values.forEach { it.complete(ConflictResolution.Skip) }
        conflictDecisions.clear()
        transferJobs.values.forEach { it.cancel() }
        transferJobs.clear()
        scope.cancel()
    }
}
