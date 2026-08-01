package com.jetsetslow.omniterm.shared.platform

import com.jetsetslow.omniterm.shared.core.OperationId
import kotlinx.coroutines.flow.Flow

sealed interface CapabilityResult<out T> {
    data class Available<T>(val value: T) : CapabilityResult<T>
    data class Unsupported(val reason: String) : CapabilityResult<Nothing>
    data class Failed(val error: PlatformError) : CapabilityResult<Nothing>
}

sealed interface PlatformError {
    data object Cancelled : PlatformError
    data object PermissionDenied : PlatformError
    data object AuthenticationFailed : PlatformError
    data object NetworkUnavailable : PlatformError
    data object HostKeyRejected : PlatformError
    data object NotFound : PlatformError
    data object StorageUnavailable : PlatformError
    data class Protocol(val code: String) : PlatformError
}

data class TransferProgress(val completedBytes: Long, val totalBytes: Long?) {
    val fraction: Float?
        get() = totalBytes?.takeIf { it > 0 }?.let { (completedBytes.toDouble() / it).coerceIn(0.0, 1.0).toFloat() }
}

interface CancellableOperation {
    val id: OperationId
    fun cancel()
}

data class SshEndpoint(val host: String, val port: Int, val username: String)
data class HostKey(val algorithm: String, val fingerprint: String)
data class CommandResult(val exitCode: Int, val stdout: String, val stderr: String)

interface SshShell : CancellableOperation {
    val output: Flow<ByteArray>
    suspend fun send(bytes: ByteArray): CapabilityResult<Unit>
    suspend fun resize(columns: Int, rows: Int): CapabilityResult<Unit>
    suspend fun close()
}

interface SshAdapter {
    suspend fun presentedHostKey(endpoint: SshEndpoint): CapabilityResult<HostKey>
    suspend fun command(endpoint: SshEndpoint, command: String): CapabilityResult<CommandResult>
    suspend fun openShell(endpoint: SshEndpoint, columns: Int, rows: Int): CapabilityResult<SshShell>
}

data class RemoteEntry(val path: String, val directory: Boolean, val size: Long, val modifiedEpochMillis: Long?)

interface ByteSource { suspend fun read(buffer: ByteArray): Int; suspend fun close() }
interface ByteSink { suspend fun write(buffer: ByteArray, count: Int); suspend fun close() }

interface SftpAdapter {
    suspend fun list(path: String): CapabilityResult<List<RemoteEntry>>
    suspend fun download(path: String, sink: ByteSink, progress: (TransferProgress) -> Unit): CapabilityResult<Unit>
    suspend fun upload(path: String, source: ByteSource, totalBytes: Long?, progress: (TransferProgress) -> Unit): CapabilityResult<Unit>
    fun cancel(operationId: OperationId)
}

interface SecretStorage {
    suspend fun store(key: String, value: ByteArray): CapabilityResult<Unit>
    suspend fun read(key: String): CapabilityResult<ByteArray?>
    suspend fun remove(key: String): CapabilityResult<Unit>
}

enum class AuthenticationReason { UnlockApp, RevealSecret, ConfirmSensitiveAction }
interface BiometricAuthenticator { suspend fun authenticate(reason: AuthenticationReason): CapabilityResult<Unit>; fun cancel() }

data class AlertNotification(
    val id: String,
    val title: String,
    val body: String,
    val route: NotificationRoute,
    val private: Boolean,
)
data class NotificationRoute(val hostId: Int?, val alertId: Int?)
interface NotificationAdapter {
    suspend fun requestPermission(): CapabilityResult<Boolean>
    suspend fun publish(notification: AlertNotification): CapabilityResult<Unit>
    suspend fun remove(ids: Set<String>): CapabilityResult<Unit>
}

enum class ApplicationVisibility { Foreground, Background }
interface ApplicationLifecycle { val visibility: Flow<ApplicationVisibility> }

data class PlatformFile(val token: String, val displayName: String, val size: Long?)
interface DocumentAdapter {
    suspend fun pickForImport(allowedTypes: Set<String>): CapabilityResult<PlatformFile?>
    suspend fun createForExport(suggestedName: String, contentType: String): CapabilityResult<PlatformFile?>
    suspend fun openRead(file: PlatformFile): CapabilityResult<ByteSource>
    suspend fun openWrite(file: PlatformFile): CapabilityResult<ByteSink>
    suspend fun discardIncomplete(file: PlatformFile)
}

interface ExternalViewer { suspend fun open(file: PlatformFile): CapabilityResult<Unit>; suspend fun openUrl(url: String): CapabilityResult<Unit> }
interface ClipboardAdapter { suspend fun readText(): CapabilityResult<String?>; suspend fun writeText(value: String): CapabilityResult<Unit> }
data class WidgetSnapshot(val generatedAtEpochMillis: Long, val online: Int, val total: Int, val stale: Boolean)
interface WidgetPublisher { suspend fun publish(snapshot: WidgetSnapshot): CapabilityResult<Unit> }
interface LocalNetworkCapability { suspend fun requestAccess(): CapabilityResult<Boolean> }
interface EntitlementAdapter { val entitled: Flow<Boolean>; suspend fun restore(): CapabilityResult<Boolean> }
