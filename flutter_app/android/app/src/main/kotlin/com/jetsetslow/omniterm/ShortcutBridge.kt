package com.jetsetslow.omniterm

import android.content.Context
import android.content.Intent
import android.content.pm.ShortcutInfo
import android.content.pm.ShortcutManager
import android.graphics.drawable.Icon
import android.os.Build
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/** Android launcher shortcut implementation used by the cross-platform Dart facade. */
object ShortcutBridge {
    private const val CHANNEL = "omniterm/shortcuts"
    private val flags =
        Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP

    fun register(engine: FlutterEngine, context: Context) {
        MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.N_MR1) {
                result.success(false)
                return@setMethodCallHandler
            }
            val manager = context.getSystemService(ShortcutManager::class.java)
            val args = call.arguments as? Map<*, *> ?: emptyMap<Any, Any>()
            when (call.method) {
                "pinServer" -> {
                    val shortcut = serverShortcut(context, args)
                    result.success(
                        Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
                            manager.isRequestPinShortcutSupported &&
                            manager.requestPinShortcut(shortcut, null),
                    )
                }
                "pushServer" -> result.success(upsert(manager, serverShortcut(context, args)))
                "pushSplit" -> result.success(upsert(manager, splitShortcut(context, args)))
                "pushShare" -> result.success(upsert(manager, shareShortcut(context, args)))
                "reportServerUsed" -> {
                    manager.reportShortcutUsed("server_${args.int("id")}")
                    result.success(true)
                }
                "removeServer" -> {
                    val id = args.int("id")
                    val doomed = manager.dynamicShortcuts.map { it.id }.filter {
                        it == "server_$id" ||
                            (it.startsWith("split_") && it.split("_").drop(1).contains(id.toString()))
                    }.plus("server_$id").distinct()
                    manager.removeDynamicShortcuts(doomed)
                    manager.disableShortcuts(doomed, "Host removed")
                    result.success(true)
                }
                "removeShare" -> {
                    val id = "share_${args.int("id")}"
                    manager.removeDynamicShortcuts(listOf(id))
                    manager.disableShortcuts(listOf(id), "Share removed")
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun serverShortcut(context: Context, args: Map<*, *>): ShortcutInfo {
        val id = args.int("id")
        val name = args.text("name").ifBlank { args.text("host") }
        return shortcut(
            context,
            "server_$id",
            name,
            "Connect to $name",
            Intent(context, MainActivity::class.java).putExtra("shortcut_server_id", id),
        )
    }

    private fun splitShortcut(context: Context, args: Map<*, *>): ShortcutInfo {
        val first = args.int("firstId")
        val second = args.int("secondId")
        val firstName = args.text("firstName")
        val secondName = args.text("secondName")
        return shortcut(
            context,
            "split_${first}_$second",
            "Split: $firstName / $secondName",
            "Split Terminal: $firstName and $secondName",
            Intent(context, MainActivity::class.java)
                .putExtra("shortcut_split_server1_id", first)
                .putExtra("shortcut_split_server2_id", second),
        )
    }

    private fun shareShortcut(context: Context, args: Map<*, *>): ShortcutInfo {
        val id = args.int("id")
        val name = args.text("name").ifBlank { args.text("address") }
        return shortcut(
            context,
            "share_$id",
            "Share: $name",
            "Open Network Share $name",
            Intent(context, MainActivity::class.java).putExtra("shortcut_share_id", id),
        )
    }

    private fun shortcut(
        context: Context,
        id: String,
        shortLabel: String,
        longLabel: String,
        intent: Intent,
    ): ShortcutInfo = ShortcutInfo.Builder(context, id)
        .setShortLabel(shortLabel.take(40))
        .setLongLabel(longLabel.take(80))
        .setIcon(Icon.createWithResource(context, R.mipmap.ic_launcher))
        .setIntent(intent.apply { action = Intent.ACTION_VIEW; flags = this@ShortcutBridge.flags })
        .build()

    private fun upsert(manager: ShortcutManager, shortcut: ShortcutInfo): Boolean {
        val present = manager.dynamicShortcuts.any { it.id == shortcut.id }
        return if (present) manager.updateShortcuts(listOf(shortcut)) else manager.addDynamicShortcuts(listOf(shortcut))
    }

    private fun Map<*, *>.int(key: String) = (this[key] as? Number)?.toInt() ?: 0
    private fun Map<*, *>.text(key: String) = this[key]?.toString().orEmpty()
}
