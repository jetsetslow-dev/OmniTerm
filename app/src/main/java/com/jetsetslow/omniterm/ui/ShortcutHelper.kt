package com.jetsetslow.omniterm.ui

import android.content.Context
import android.content.Intent
import androidx.core.content.pm.ShortcutInfoCompat
import androidx.core.content.pm.ShortcutManagerCompat
import androidx.core.graphics.drawable.IconCompat
import com.jetsetslow.omniterm.MainActivity
import com.jetsetslow.omniterm.R
import com.jetsetslow.omniterm.data.ServerEntity

object ShortcutHelper {
    fun pushServerShortcut(context: Context, server: ServerEntity) {
        val intent = Intent(context, MainActivity::class.java).apply {
            action = Intent.ACTION_VIEW
            putExtra("shortcut_server_id", server.id)
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK
        }

        val name = server.name.takeIf { !it.isNullOrBlank() } ?: server.host
        val shortcut = ShortcutInfoCompat.Builder(context, "server_${server.id}")
            .setShortLabel(name)
            .setLongLabel("Connect to $name")
            .setIcon(IconCompat.createWithResource(context, R.mipmap.ic_launcher))
            .setIntent(intent)
            .build()

        ShortcutManagerCompat.pushDynamicShortcut(context, shortcut)
    }

    fun pushSplitTerminalShortcut(context: Context, server1: ServerEntity, server2: ServerEntity) {
        val intent = Intent(context, MainActivity::class.java).apply {
            action = Intent.ACTION_VIEW
            putExtra("shortcut_split_server1_id", server1.id)
            putExtra("shortcut_split_server2_id", server2.id)
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK
        }

        val name1 = server1.name.takeIf { !it.isNullOrBlank() } ?: server1.host
        val name2 = server2.name.takeIf { !it.isNullOrBlank() } ?: server2.host
        val shortcut = ShortcutInfoCompat.Builder(context, "split_${server1.id}_${server2.id}")
            .setShortLabel("Split: $name1 / $name2")
            .setLongLabel("Split Terminal: $name1 and $name2")
            .setIcon(IconCompat.createWithResource(context, R.mipmap.ic_launcher))
            .setIntent(intent)
            .build()

        ShortcutManagerCompat.pushDynamicShortcut(context, shortcut)
    }

    fun pushNetworkShareShortcut(context: Context, share: com.jetsetslow.omniterm.data.NetworkShareEntity) {
        val intent = Intent(context, MainActivity::class.java).apply {
            action = Intent.ACTION_VIEW
            putExtra("shortcut_share_id", share.id)
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK
        }

        val name = share.name.takeIf { !it.isNullOrBlank() } ?: share.address
        val shortcut = ShortcutInfoCompat.Builder(context, "share_${share.id}")
            .setShortLabel("Share: $name")
            .setLongLabel("Open Network Share $name")
            .setIcon(IconCompat.createWithResource(context, R.mipmap.ic_launcher))
            .setIntent(intent)
            .build()

        ShortcutManagerCompat.pushDynamicShortcut(context, shortcut)
    }
}
