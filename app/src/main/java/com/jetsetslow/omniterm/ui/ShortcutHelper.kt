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
}
