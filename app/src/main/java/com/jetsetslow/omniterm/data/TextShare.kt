package com.jetsetslow.omniterm.data

import android.content.Context
import android.content.Intent
import androidx.core.content.FileProvider
import java.io.File

/**
 * Opens the Android share sheet with a text report: the crash report, a Fleet run's output. The
 * user picks where it goes; nothing is sent by the app itself.
 *
 * The text goes in the message body as well as an attached file, because many targets (Gmail,
 * messaging, notes) keep the body and drop the attachment. A long report goes as the file alone:
 * the whole share sheet request travels in one Binder transaction, and a body of several hundred
 * kilobytes fails it with TransactionTooLargeException. The file sits in a cache folder that
 * `res/xml/file_paths.xml` exposes through the app's own FileProvider, and nowhere else.
 */
object TextShare {
    /** The longest report sent as the message body too. */
    const val MAX_INLINE_CHARS = 100_000

    fun share(
        context: Context,
        text: String,
        subject: String,
        fileName: String,
        chooserTitle: String,
        cacheFolder: String,
    ) {
        val send = Intent(Intent.ACTION_SEND).apply {
            type = "text/plain"
            putExtra(Intent.EXTRA_SUBJECT, subject)
            if (text.length <= MAX_INLINE_CHARS) putExtra(Intent.EXTRA_TEXT, text)
        }
        val attached = runCatching {
            val dir = File(context.cacheDir, cacheFolder).apply { mkdirs() }
            val file = File(dir, fileName)
            file.writeText(text)
            val uri = FileProvider.getUriForFile(context, "${context.packageName}.fileprovider", file)
            send.putExtra(Intent.EXTRA_STREAM, uri)
            send.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }.isSuccess
        // Without the file a long report still goes, cut to what fits in the body.
        if (!attached && text.length > MAX_INLINE_CHARS) {
            send.putExtra(Intent.EXTRA_TEXT, text.take(MAX_INLINE_CHARS) + "\n[cut: the full text could not be attached]")
        }
        context.startActivity(Intent.createChooser(send, chooserTitle).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
    }
}
