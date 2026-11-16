package com.jetsetslow.omniterm.ui

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue

/** A fixed, runtime-only selection. All open is a snapshot, never a subscription. */
internal class TerminalTyping {
    var selectedIds by mutableStateOf(emptySet<String>())
        private set
    var revision by mutableStateOf(0L)
        private set
    val enabled get() = selectedIds.isNotEmpty()

    fun select(ids: Set<String>, sessions: List<ShellSession>) {
        selectedIds = sessions.filter { it.id in ids && !it.userClosed }.map { it.id }.toSet()
        revision++
    }

    fun stop() {
        selectedIds = emptySet()
        revision++
    }

    fun remove(id: String) {
        if (id in selectedIds) {
            selectedIds = selectedIds - id
            revision++
        }
    }

    fun exclusion(session: ShellSession): String? = when {
        session.inputLocked -> "input locked"
        session.reconnecting -> "reconnecting"
        !session.isConnected || session.userClosed || session.session.closed.value -> "disconnected"
        else -> null
    }

    fun receivers(focused: ShellSession?, sessions: List<ShellSession>): List<ShellSession> {
        if (focused == null || exclusion(focused) != null) return emptyList()
        return if (enabled) sessions.filter { it.id in selectedIds && exclusion(it) == null }
        else listOf(focused)
    }
}
