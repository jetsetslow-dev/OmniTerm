package com.jetsetslow.omniterm.ui

/**
 * Platform-neutral latest-operation-wins coordination.
 *
 * Long-running UI work often cannot be cancelled once it has crossed into a platform API.  A
 * generation token still prevents an older completion from replacing the result of a newer user
 * request.  Keeping this free of Android and Compose types makes the policy directly portable to
 * a shared Kotlin/iOS presentation layer.
 */
internal class OperationGeneration<Key> {
    private val generations = mutableMapOf<Key, Long>()

    @Synchronized
    fun begin(keys: Collection<Key>): Map<Key, Long> =
        keys.associateWith { key ->
            val next = (generations[key] ?: 0L) + 1L
            generations[key] = next
            next
        }

    @Synchronized
    fun isCurrent(key: Key, generation: Long): Boolean = generations[key] == generation

    /** Runs publication atomically with respect to [begin], closing the check-then-publish race. */
    fun publishIfCurrent(key: Key, generation: Long, publish: () -> Unit): Boolean =
        synchronized(this) {
            if (generations[key] != generation) return@synchronized false
            publish()
            true
        }

    @Synchronized
    fun forget(keys: Collection<Key>) {
        keys.forEach(generations::remove)
    }
}
