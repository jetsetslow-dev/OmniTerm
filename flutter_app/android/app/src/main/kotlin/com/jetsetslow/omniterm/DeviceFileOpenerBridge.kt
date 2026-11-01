package com.jetsetslow.omniterm

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Intent
import android.webkit.MimeTypeMap
import androidx.core.content.FileProvider
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.Locale

/**
 * "Open with device app" for a remote file, ported from `openRemoteFileWithDevice` in the Kotlin
 * app's `ui/AppViewModel.kt`: Dart downloads the file into [PREVIEW_DIR] under the app's private
 * cache, and this hands it to the device's own viewers (photos, video, PDF) through the
 * FileProvider with a read grant and a chooser.
 *
 * Only that one cache subdirectory is exposed (`res/xml/file_paths.xml`), and [open] refuses any
 * path outside it, so the channel cannot be used to share other app data.
 */
object DeviceFileOpenerBridge {
    private const val CHANNEL = "omniterm/file_opener"
    private const val PREVIEW_DIR = "remote-previews"

    fun register(engine: FlutterEngine, activity: Activity) {
        MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                // Emptied on each preview, as in Kotlin: one opened file at a time is kept.
                "previewDirectory" -> {
                    val dir = File(activity.cacheDir, PREVIEW_DIR)
                    dir.mkdirs()
                    dir.listFiles()?.forEach { it.deleteRecursively() }
                    result.success(dir.absolutePath)
                }
                "open" -> result.success(open(activity, call.argument<String>("path").orEmpty()))
                else -> result.notImplemented()
            }
        }
    }

    private fun open(activity: Activity, path: String): String {
        val dir = File(activity.cacheDir, PREVIEW_DIR).canonicalFile
        val file = File(path).canonicalFile
        if (file.parentFile != dir || !file.isFile) return "refused"
        val uri = FileProvider.getUriForFile(activity, "${activity.packageName}.fileprovider", file)
        val ext = file.name.substringAfterLast('.', "").lowercase(Locale.ROOT)
        val mime = MimeTypeMap.getSingleton().getMimeTypeFromExtension(ext) ?: "*/*"
        val view = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, mime)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        return try {
            activity.startActivity(Intent.createChooser(view, "Open ${file.name} with…"))
            "opened"
        } catch (_: ActivityNotFoundException) {
            "no_app"
        }
    }
}
