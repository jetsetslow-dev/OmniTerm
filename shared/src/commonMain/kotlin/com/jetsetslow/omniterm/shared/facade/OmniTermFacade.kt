package com.jetsetslow.omniterm.shared.facade

/** Small, intentionally nongeneric API exported to Swift. */
data class SwiftShellSnapshot(
    val initializing: Boolean,
    val title: String,
    val errorMessage: String?,
)

class Observation internal constructor(private var cancelAction: (() -> Unit)?) {
    fun cancel() {
        cancelAction?.invoke()
        cancelAction = null
    }
}

class OmniTermFacade {
    private var snapshot = SwiftShellSnapshot(initializing = false, title = "OmniTerm", errorMessage = null)
    private val observers = mutableMapOf<Long, (SwiftShellSnapshot) -> Unit>()
    private var nextObserverId = 0L

    fun currentSnapshot(): SwiftShellSnapshot = snapshot

    /** The callback is invoked synchronously on the caller thread and after every subsequent event. */
    fun observe(observer: (SwiftShellSnapshot) -> Unit): Observation {
        val id = ++nextObserverId
        observers[id] = observer
        observer(snapshot)
        return Observation { observers.remove(id) }
    }

    fun retry() {
        update(snapshot.copy(initializing = false, errorMessage = null))
    }

    fun close() {
        observers.clear()
    }

    private fun update(value: SwiftShellSnapshot) {
        snapshot = value
        observers.values.toList().forEach { it(value) }
    }
}
