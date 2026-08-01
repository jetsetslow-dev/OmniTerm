package com.jetsetslow.omniterm.shared.core

import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.updateAndGet

fun interface WallClock {
    fun nowEpochMillis(): Long
}

fun interface MonotonicClock {
    fun nowMillis(): Long
}

fun interface IdGenerator {
    fun nextId(): String
}

data class DispatcherProvider(
    val main: CoroutineDispatcher,
    val io: CoroutineDispatcher,
    val cpu: CoroutineDispatcher,
)

enum class PlatformFamily { Android, Ios, Unknown }

enum class PlatformCapability {
    Ssh,
    Sftp,
    WebDav,
    LocalNetwork,
    Biometrics,
    Notifications,
    Documents,
    Clipboard,
    Widget,
    Purchases,
    Advertising,
    ReviewPrompt,
}

data class PlatformInfo(
    val family: PlatformFamily,
    val osVersion: String,
    val capabilities: Set<PlatformCapability>,
) {
    fun supports(capability: PlatformCapability): Boolean = capability in capabilities
}

enum class LogLevel { Debug, Info, Warning, Error }

data class DiagnosticEvent(
    val name: String,
    val fields: Map<String, String> = emptyMap(),
    val level: LogLevel = LogLevel.Info,
)

fun interface DiagnosticLogger {
    /** Implementations receive already-redacted values and must never append terminal contents. */
    fun log(event: DiagnosticEvent)
}

data class OperationId(val value: String)

class OperationGeneration {
    private val generation = MutableStateFlow(0L)

    fun next(): Long = generation.updateAndGet { it + 1 }

    fun isCurrent(candidate: Long): Boolean = candidate == generation.value

    fun invalidate() {
        generation.updateAndGet { it + 1 }
    }
}
