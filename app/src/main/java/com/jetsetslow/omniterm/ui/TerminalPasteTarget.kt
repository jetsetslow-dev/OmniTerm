package com.jetsetslow.omniterm.ui

import com.jetsetslow.omniterm.data.ssh.TerminalSession

/** An input decision belongs to the pane and connection visible when the user made it. */
internal data class TerminalPasteTarget(
    val shell: ShellSession,
    val transport: TerminalSession = shell.session,
    val queue: TerminalInputQueue? = shell.terminalInputQueue,
    val controlMode: Boolean = shell.controlMode,
    val paneId: String? = if (controlMode) shell.activePaneId else null,
    val paneRevision: Long = if (controlMode) shell.controlPaneChangeRevision.get() else 0,
) {
    fun rejection(focused: ShellSession?, readOnly: Boolean): String? = when {
        readOnly -> "Disable read-only mode before pasting."
        focused !== shell -> "Terminal selection changed. Paste skipped; select the intended session and paste again."
        shell.session !== transport || shell.terminalInputQueue !== queue || shell.controlMode != controlMode ->
            "Connection changed. Paste skipped; check the terminal and paste again."
        !shell.isConnected || transport.closed.value || queue == null || synchronized(queue) { queue.closed } ->
            "Terminal is disconnected. Reconnect before pasting."
        controlMode && (shell.activePaneId != paneId || shell.controlPaneChangeRevision.get() != paneRevision) ->
            "Terminal pane changed. Paste skipped; select the intended pane and paste again."
        controlMode && (!shell.controlReady || paneId == null) ->
            "Wait for tmux to finish selecting its pane before pasting."
        else -> null
    }
}

internal data class PendingTerminalPaste(val text: String, val target: TerminalPasteTarget)

/** Session ownership preserves pending/result feedback through Activity recreation. */
data class TerminalPasteFeedback(val message: String, val busy: Boolean = false)
