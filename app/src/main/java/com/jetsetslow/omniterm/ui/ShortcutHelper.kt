package com.jetsetslow.omniterm.ui

import android.content.Context
import android.content.Intent
import androidx.core.content.pm.ShortcutInfoCompat
import androidx.core.content.pm.ShortcutManagerCompat
import androidx.core.graphics.drawable.IconCompat
import com.jetsetslow.omniterm.MainActivity
import com.jetsetslow.omniterm.R
import com.jetsetslow.omniterm.data.NetworkShareEntity
import com.jetsetslow.omniterm.data.ServerEntity

object ShortcutHelper {

    fun serverShortcutId(serverId: Int) = "server_$serverId"
    fun shareShortcutId(shareId: Int) = "share_$shareId"

    private fun serverIntent(context: Context, serverId: Int) =
        Intent(context, MainActivity::class.java).apply {
            action = Intent.ACTION_VIEW
            putExtra("shortcut_server_id", serverId)
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK
        }

    private fun buildServerShortcut(context: Context, server: ServerEntity): ShortcutInfoCompat {
        val name = server.name.takeIf { it.isNotBlank() } ?: server.host
        return ShortcutInfoCompat.Builder(context, serverShortcutId(server.id))
            .setShortLabel(name)
            .setLongLabel("Connect to $name")
            .setIcon(IconCompat.createWithResource(context, R.drawable.ic_shortcut_terminal))
            .setIntent(serverIntent(context, server.id))
            .build()
    }

    fun pushServerShortcut(context: Context, server: ServerEntity) {
        ShortcutManagerCompat.pushDynamicShortcut(context, buildServerShortcut(context, server))
    }

    /** Offer to pin this host's shortcut to the home screen (no-op on unsupported launchers). */
    fun pinServerShortcut(context: Context, server: ServerEntity) {
        if (ShortcutManagerCompat.isRequestPinShortcutSupported(context)) {
            ShortcutManagerCompat.requestPinShortcut(context, buildServerShortcut(context, server), null)
        }
    }

    fun pushSplitTerminalShortcut(context: Context, server1: ServerEntity, server2: ServerEntity) {
        val intent = Intent(context, MainActivity::class.java).apply {
            action = Intent.ACTION_VIEW
            putExtra("shortcut_split_server1_id", server1.id)
            putExtra("shortcut_split_server2_id", server2.id)
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK
        }

        val name1 = server1.name.takeIf { it.isNotBlank() } ?: server1.host
        val name2 = server2.name.takeIf { it.isNotBlank() } ?: server2.host
        val shortcut = ShortcutInfoCompat.Builder(context, "split_${server1.id}_${server2.id}")
            .setShortLabel("Split: $name1 / $name2")
            .setLongLabel("Split Terminal: $name1 and $name2")
            .setIcon(IconCompat.createWithResource(context, R.drawable.ic_shortcut_split))
            .setIntent(intent)
            .build()

        ShortcutManagerCompat.pushDynamicShortcut(context, shortcut)
    }

    fun pushNetworkShareShortcut(context: Context, share: NetworkShareEntity) {
        val intent = Intent(context, MainActivity::class.java).apply {
            action = Intent.ACTION_VIEW
            putExtra("shortcut_share_id", share.id)
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK
        }

        val name = share.name.takeIf { it.isNotBlank() } ?: share.address
        val shortcut = ShortcutInfoCompat.Builder(context, shareShortcutId(share.id))
            .setShortLabel("Share: $name")
            .setLongLabel("Open Network Share $name")
            .setIcon(IconCompat.createWithResource(context, R.drawable.ic_shortcut_share))
            .setIntent(intent)
            .build()

        ShortcutManagerCompat.pushDynamicShortcut(context, shortcut)
    }

    /** Let the launcher rank frequently used hosts even when opened from inside the app. */
    fun reportServerShortcutUsed(context: Context, serverId: Int) {
        ShortcutManagerCompat.reportShortcutUsed(context, serverShortcutId(serverId))
    }

    /**
     * A deleted host must not leave a dead launcher entry behind: remove its dynamic shortcut
     * (and any split shortcut referencing it) and disable pinned copies with an explanation.
     */
    fun removeShortcutsForServer(context: Context, serverId: Int) {
        val doomed = ShortcutManagerCompat.getDynamicShortcuts(context)
            .map { it.id }
            .filter {
                it == serverShortcutId(serverId) ||
                    (it.startsWith("split_") && it.split("_").drop(1).contains(serverId.toString()))
            }
        val allDoomed = (doomed + serverShortcutId(serverId)).distinct()
        ShortcutManagerCompat.removeDynamicShortcuts(context, allDoomed)
        ShortcutManagerCompat.disableShortcuts(context, allDoomed, "Host removed")
    }

    fun removeShortcutForShare(context: Context, shareId: Int) {
        val id = shareShortcutId(shareId)
        ShortcutManagerCompat.removeDynamicShortcuts(context, listOf(id))
        ShortcutManagerCompat.disableShortcuts(context, listOf(id), "Share removed")
    }

    /** Refresh the label/icon of an existing dynamic shortcut after a rename; no-op otherwise. */
    fun refreshServerShortcutIfPresent(context: Context, server: ServerEntity) {
        val present = ShortcutManagerCompat.getDynamicShortcuts(context)
            .any { it.id == serverShortcutId(server.id) }
        if (present) pushServerShortcut(context, server)
    }
}
