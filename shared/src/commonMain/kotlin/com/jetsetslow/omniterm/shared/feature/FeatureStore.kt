package com.jetsetslow.omniterm.shared.feature

import com.jetsetslow.omniterm.shared.core.OperationGeneration
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

data class OperationProgress(
    val message: String,
    val completed: Long? = null,
    val total: Long? = null,
) {
    val fraction: Float?
        get() = if (completed != null && total != null && total > 0) {
            (completed.toDouble() / total).coerceIn(0.0, 1.0).toFloat()
        } else null
}

data class LoadState<T>(
    val value: T,
    val loading: Boolean = false,
    val progress: OperationProgress? = null,
    val error: String? = null,
    val stale: Boolean = false,
)

sealed interface StoreEffect {
    data class Message(val text: String) : StoreEffect
    data class Navigate(val route: String) : StoreEffect
}

interface FeatureStore<S, A> {
    val state: StateFlow<S>
    val effects: SharedFlow<StoreEffect>
    fun dispatch(action: A)
    fun close()
}

fun interface ProgressLoader<T> {
    suspend fun load(reportProgress: (OperationProgress) -> Unit): T
}

/** Reference implementation for latest-wins load, refresh, retry, progress, and cancellation. */
class RefreshStore<T>(
    initial: T,
    private val scope: CoroutineScope,
    private val loader: ProgressLoader<T>,
    private val errorText: (Throwable) -> String = { "Operation failed" },
) : FeatureStore<LoadState<T>, RefreshStore.Action> {
    sealed interface Action {
        data object Load : Action
        data object Refresh : Action
        data object Retry : Action
        data object Cancel : Action
    }

    private val mutableState = MutableStateFlow(LoadState(initial))
    override val state: StateFlow<LoadState<T>> = mutableState.asStateFlow()
    private val mutableEffects = MutableSharedFlow<StoreEffect>(extraBufferCapacity = 4)
    override val effects: SharedFlow<StoreEffect> = mutableEffects.asSharedFlow()
    private val generation = OperationGeneration()
    private var operation: Job? = null

    override fun dispatch(action: Action) {
        when (action) {
            Action.Load, Action.Refresh, Action.Retry -> start()
            Action.Cancel -> cancel()
        }
    }

    private fun start() {
        operation?.cancel()
        val owner = generation.next()
        mutableState.value = mutableState.value.copy(loading = true, progress = null, error = null)
        operation = scope.launch {
            runCatching {
                loader.load { progress ->
                    if (generation.isCurrent(owner)) {
                        mutableState.value = mutableState.value.copy(loading = true, progress = progress)
                    }
                }
            }.onSuccess { value ->
                if (generation.isCurrent(owner)) {
                    mutableState.value = LoadState(value = value)
                }
            }.onFailure { error ->
                if (generation.isCurrent(owner) && error !is kotlinx.coroutines.CancellationException) {
                    val message = errorText(error)
                    mutableState.value = mutableState.value.copy(
                        loading = false,
                        progress = null,
                        error = message,
                        stale = true,
                    )
                    mutableEffects.tryEmit(StoreEffect.Message(message))
                }
            }
        }
    }

    private fun cancel() {
        generation.invalidate()
        operation?.cancel()
        operation = null
        mutableState.value = mutableState.value.copy(loading = false, progress = null)
    }

    override fun close() {
        cancel()
        scope.cancel()
    }
}
