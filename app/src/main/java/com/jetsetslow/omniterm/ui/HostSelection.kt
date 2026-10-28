package com.jetsetslow.omniterm.ui

import androidx.compose.runtime.mutableStateMapOf

/**
 * Keys picked on each host: a list's multi-select, or which of its rows are open.
 *
 * Kept per host because users switch hosts often and do the same or different work on each. Rows
 * picked on one host must never be acted on while another is shown (most hosts have a volume
 * called `data`, and a pulled image has the same id everywhere), and switching back finds the
 * picks as they were left.
 */
class HostSelection {
    private val picked = mutableStateMapOf<Int, Set<String>>()
    private val selecting = mutableStateMapOf<Int, Boolean>()

    /** Whether [host]'s list is in multi-select mode. */
    fun isSelecting(host: Int?): Boolean = host != null && selecting[host] == true

    fun picked(host: Int?): Set<String> = host?.let { picked[it] }.orEmpty()

    fun isPicked(host: Int?, key: String): Boolean = key in picked(host)

    /** Turns multi-select on or off for [host]; turning it off drops that host's picks. */
    fun toggleSelecting(host: Int?) {
        host ?: return
        if (selecting.remove(host) == true) picked.remove(host) else selecting[host] = true
    }

    /** Picks [key] on [host], or un-picks it. */
    fun toggle(host: Int?, key: String) {
        host ?: return
        val keys = picked(host)
        picked[host] = if (key in keys) keys - key else keys + key
    }

    /** Ends [host]'s multi-select and drops its picks, as after acting on them. */
    fun clear(host: Int?) {
        host ?: return
        selecting.remove(host)
        picked.remove(host)
    }
}
