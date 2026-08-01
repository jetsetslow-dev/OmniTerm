package com.jetsetslow.omniterm.shared.feature

import com.jetsetslow.omniterm.data.HostMetrics
import com.jetsetslow.omniterm.shared.core.OperationGeneration
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

data class FleetHost(val id: Int, val name: String)
data class FleetReading(val host: FleetHost, val metrics: HostMetrics?, val reachable: Boolean)

interface FleetRepository {
    suspend fun hosts(): List<FleetHost>
    suspend fun probe(host: FleetHost, progress: (OperationProgress) -> Unit): FleetReading
}

fun interface PollingPolicy {
    fun nextDelayMillis(foreground: Boolean): Long?
}

data class FleetState(
    val hosts: List<FleetHost> = emptyList(),
    val readings: Map<Int, FleetReading> = emptyMap(),
    val selectedHostId: Int? = null,
    val refreshing: Boolean = false,
    val progress: OperationProgress? = null,
    val error: String? = null,
    val stale: Boolean = false,
)

sealed interface FleetAction {
    data object Refresh : FleetAction
    data object CancelRefresh : FleetAction
    data class SelectHost(val id: Int?) : FleetAction
    data class VisibilityChanged(val foreground: Boolean) : FleetAction
}

class FleetStore(
    private val scope: CoroutineScope,
    private val repository: FleetRepository,
    private val pollingPolicy: PollingPolicy,
) : FeatureStore<FleetState, FleetAction> {
    private val mutableState = MutableStateFlow(FleetState())
    override val state: StateFlow<FleetState> = mutableState.asStateFlow()
    private val mutableEffects = MutableSharedFlow<StoreEffect>(extraBufferCapacity = 4)
    override val effects: SharedFlow<StoreEffect> = mutableEffects.asSharedFlow()
    private val generation = OperationGeneration()
    private var refreshJob: Job? = null
    private var pollingJob: Job? = null
    private var foreground = true

    override fun dispatch(action: FleetAction) {
        when (action) {
            FleetAction.Refresh -> refresh()
            FleetAction.CancelRefresh -> cancelRefresh()
            is FleetAction.SelectHost -> mutableState.value = mutableState.value.copy(selectedHostId = action.id)
            is FleetAction.VisibilityChanged -> {
                foreground = action.foreground
                scheduleNextPoll()
            }
        }
    }

    private fun refresh() {
        refreshJob?.cancel()
        val owner = generation.next()
        mutableState.value = mutableState.value.copy(refreshing = true, progress = null, error = null)
        refreshJob = scope.launch {
            runCatching {
                val hosts = repository.hosts()
                val readings = buildMap {
                    hosts.forEachIndexed { index, host ->
                        if (generation.isCurrent(owner)) {
                            mutableState.value = mutableState.value.copy(
                                progress = OperationProgress("Refreshing ${host.name}", index.toLong(), hosts.size.toLong()),
                            )
                        }
                        put(host.id, repository.probe(host) { detail ->
                            if (generation.isCurrent(owner)) mutableState.value = mutableState.value.copy(progress = detail)
                        })
                    }
                }
                hosts to readings
            }.onSuccess { (hosts, readings) ->
                if (generation.isCurrent(owner)) {
                    mutableState.value = mutableState.value.copy(
                        hosts = hosts,
                        readings = readings,
                        refreshing = false,
                        progress = null,
                        error = null,
                        stale = false,
                    )
                    scheduleNextPoll()
                }
            }.onFailure { error ->
                if (generation.isCurrent(owner) && error !is kotlinx.coroutines.CancellationException) {
                    mutableState.value = mutableState.value.copy(
                        refreshing = false,
                        progress = null,
                        error = "Fleet refresh failed",
                        stale = true,
                    )
                    mutableEffects.tryEmit(StoreEffect.Message("Fleet refresh failed"))
                    scheduleNextPoll()
                }
            }
        }
    }

    private fun scheduleNextPoll() {
        pollingJob?.cancel()
        val delayMillis = pollingPolicy.nextDelayMillis(foreground) ?: return
        pollingJob = scope.launch {
            delay(delayMillis)
            refresh()
        }
    }

    private fun cancelRefresh() {
        generation.invalidate()
        refreshJob?.cancel()
        refreshJob = null
        mutableState.value = mutableState.value.copy(refreshing = false, progress = null)
    }

    override fun close() {
        cancelRefresh()
        pollingJob?.cancel()
        scope.cancel()
    }
}
