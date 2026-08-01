package com.jetsetslow.omniterm.shared.feature

import com.jetsetslow.omniterm.shared.core.OperationGeneration
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

data class AlertRuleModel(val id: Int, val name: String, val enabled: Boolean)
data class ScriptModel(val id: Int, val name: String, val body: String)
data class AppSettings(val measurementSystem: String = "metric", val privacyMode: Boolean = false)

interface AlertsRepository { suspend fun load(): List<AlertRuleModel>; suspend fun save(rule: AlertRuleModel) }
interface ScriptsRepository { suspend fun load(): List<ScriptModel>; suspend fun save(script: ScriptModel) }
interface SettingsRepository { suspend fun load(): AppSettings; suspend fun save(settings: AppSettings) }
interface BackupRepository {
    suspend fun export(progress: (OperationProgress) -> Unit)
    suspend fun import(progress: (OperationProgress) -> Unit)
}
interface NetworkToolsRepository { suspend fun run(tool: String, target: String, progress: (OperationProgress) -> Unit): String }

data class CollectionState<T>(
    val items: List<T> = emptyList(),
    val busy: Boolean = false,
    val progress: OperationProgress? = null,
    val error: String? = null,
)

sealed interface CollectionAction<out T> {
    data object Load : CollectionAction<Nothing>
    data class Save<T>(val item: T) : CollectionAction<T>
    data object Cancel : CollectionAction<Nothing>
}

class CollectionStore<T>(
    private val scope: CoroutineScope,
    private val load: suspend () -> List<T>,
    private val save: suspend (T) -> Unit,
    private val failureMessage: String,
) : FeatureStore<CollectionState<T>, CollectionAction<T>> {
    private val mutableState = MutableStateFlow(CollectionState<T>())
    override val state: StateFlow<CollectionState<T>> = mutableState.asStateFlow()
    private val mutableEffects = MutableSharedFlow<StoreEffect>(extraBufferCapacity = 4)
    override val effects: SharedFlow<StoreEffect> = mutableEffects.asSharedFlow()
    private val generation = OperationGeneration()
    private var job: Job? = null

    override fun dispatch(action: CollectionAction<T>) {
        when (action) {
            CollectionAction.Load -> launchOperation { load() }
            is CollectionAction.Save -> launchOperation { save(action.item); load() }
            CollectionAction.Cancel -> cancelOperation()
        }
    }

    private fun launchOperation(block: suspend () -> List<T>) {
        job?.cancel()
        val owner = generation.next()
        mutableState.value = mutableState.value.copy(busy = true, error = null)
        job = scope.launch {
            runCatching { block() }
                .onSuccess { if (generation.isCurrent(owner)) mutableState.value = CollectionState(items = it) }
                .onFailure {
                    if (generation.isCurrent(owner) && it !is kotlinx.coroutines.CancellationException) {
                        mutableState.value = mutableState.value.copy(busy = false, error = failureMessage)
                        mutableEffects.tryEmit(StoreEffect.Message(failureMessage))
                    }
                }
        }
    }

    private fun cancelOperation() {
        generation.invalidate()
        job?.cancel()
        job = null
        mutableState.value = mutableState.value.copy(busy = false, progress = null)
    }

    override fun close() { cancelOperation(); scope.cancel() }
}

fun AlertsStore(scope: CoroutineScope, repository: AlertsRepository): CollectionStore<AlertRuleModel> =
    CollectionStore(scope, repository::load, repository::save, "Alert update failed")

fun ScriptsStore(scope: CoroutineScope, repository: ScriptsRepository): CollectionStore<ScriptModel> =
    CollectionStore(scope, repository::load, repository::save, "Script update failed")

data class SettingsState(val value: AppSettings = AppSettings(), val loading: Boolean = false, val error: String? = null)
sealed interface SettingsAction { data object Load : SettingsAction; data class Save(val value: AppSettings) : SettingsAction; data object Cancel : SettingsAction }

class SettingsStore(
    private val scope: CoroutineScope,
    private val repository: SettingsRepository,
) : FeatureStore<SettingsState, SettingsAction> {
    private val mutableState = MutableStateFlow(SettingsState())
    override val state = mutableState.asStateFlow()
    private val mutableEffects = MutableSharedFlow<StoreEffect>(extraBufferCapacity = 4)
    override val effects = mutableEffects.asSharedFlow()
    private val generation = OperationGeneration()
    private var job: Job? = null

    override fun dispatch(action: SettingsAction) {
        when (action) {
            SettingsAction.Load -> runOperation { repository.load() }
            is SettingsAction.Save -> runOperation { repository.save(action.value); repository.load() }
            SettingsAction.Cancel -> cancelOperation()
        }
    }

    private fun runOperation(block: suspend () -> AppSettings) {
        job?.cancel()
        val owner = generation.next()
        mutableState.value = mutableState.value.copy(loading = true, error = null)
        job = scope.launch {
            runCatching { block() }.onSuccess {
                if (generation.isCurrent(owner)) mutableState.value = SettingsState(value = it)
            }.onFailure {
                if (generation.isCurrent(owner) && it !is kotlinx.coroutines.CancellationException) {
                    // Preserve the last confirmed value: a failed write must never look committed.
                    mutableState.value = mutableState.value.copy(loading = false, error = "Settings were not saved")
                    mutableEffects.tryEmit(StoreEffect.Message("Settings were not saved"))
                }
            }
        }
    }

    private fun cancelOperation() { generation.invalidate(); job?.cancel(); job = null; mutableState.value = mutableState.value.copy(loading = false) }
    override fun close() { cancelOperation(); scope.cancel() }
}

class BackupStore(private val scope: CoroutineScope, repository: BackupRepository) {
    private fun operationScope() = CoroutineScope(scope.coroutineContext + SupervisorJob(scope.coroutineContext[Job]))
    val export = RefreshStore(Unit, operationScope(), ProgressLoader { repository.export(it) })
    val import = RefreshStore(Unit, operationScope(), ProgressLoader { repository.import(it) })

    fun close() {
        export.close()
        import.close()
    }
}

data class NetworkToolRequest(val tool: String, val target: String)

class NetworkToolsStore(scope: CoroutineScope, repository: NetworkToolsRepository) {
    private var request = NetworkToolRequest("", "")
    val operation = RefreshStore("", scope, ProgressLoader { progress ->
        require(request.tool.isNotBlank() && request.target.isNotBlank())
        repository.run(request.tool, request.target, progress)
    })

    fun run(request: NetworkToolRequest) {
        this.request = request
        operation.dispatch(RefreshStore.Action.Refresh)
    }
}
