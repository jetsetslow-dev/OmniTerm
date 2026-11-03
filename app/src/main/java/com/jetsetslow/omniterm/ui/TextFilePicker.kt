package com.jetsetslow.omniterm.ui

import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.runtime.Composable
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalResources
import com.jetsetslow.omniterm.R
import java.io.InputStream

/** Small text files the user picks: an SSH key, an ssh_config. A megabyte is far more than either. */
internal const val TEXT_FILE_MAX_CHARS = 1024 * 1024

/**
 * Opens the system file picker and hands over the picked file's text. A file that cannot be read,
 * or is larger than [maxChars], says so instead.
 */
@Composable
internal fun rememberTextFilePicker(maxChars: Int = TEXT_FILE_MAX_CHARS, onRead: (String) -> Unit): () -> Unit {
    val context = LocalContext.current
    val resources = LocalResources.current
    val launcher = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        if (uri != null) {
            try {
                context.contentResolver.openInputStream(uri)?.use { onRead(readTextLimited(it, maxChars)) }
            } catch (e: Exception) {
                android.util.Log.w("TextFilePicker", "Failed to read the picked file", e)
                android.widget.Toast.makeText(context, resources.getString(R.string.could_not_read_file, e.message), android.widget.Toast.LENGTH_SHORT).show()
            }
        }
    }
    // Configs and keys often have no extension or a type the provider does not know.
    return { launcher.launch(arrayOf("*/*")) }
}

/** Reads [input] as UTF-8, failing once it passes [maxChars] instead of filling memory with it. */
internal fun readTextLimited(input: InputStream, maxChars: Int, tooLarge: String = "The file is too large to read."): String {
    input.reader(Charsets.UTF_8).use { reader ->
        val out = StringBuilder()
        val buffer = CharArray(8192)
        while (true) {
            val read = reader.read(buffer)
            if (read < 0) return out.toString()
            if (out.length + read > maxChars) throw IllegalArgumentException(tooLarge)
            out.append(buffer, 0, read)
        }
    }
}
