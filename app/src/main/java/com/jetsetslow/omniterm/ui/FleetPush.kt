package com.jetsetslow.omniterm.ui

import java.io.File
import java.io.InputStream
import java.io.OutputStream

/**
 * A file Fleet pushes to many hosts over SFTP: a copy of the picked file kept on the phone
 * ([local], [size] bytes), and where it goes on each host ([destination], as typed).
 *
 * Idea credit: Termix Fleets' file pushes (docs.termix.site/plugins/fleets).
 */
data class FleetPush(
    val fileName: String,
    val size: Long,
    val local: File,
    val destination: String,
) {
    /**
     * Where the file goes on a host whose home folder is [home]. A path ending in `/` (or `~`, or
     * nothing) is a folder, and the file keeps its name there; any other path is the file's new
     * name. A path not starting with `/` is in the home folder.
     */
    fun remotePath(home: String): String {
        val dest = destination.trim()
        val base = home.trimEnd('/')
        val absolute = when {
            dest.isEmpty() || dest == "~" -> "$base/"
            dest.startsWith("~/") -> "$base/${dest.removePrefix("~/")}"
            dest.startsWith("/") -> dest
            else -> "$base/$dest"
        }
        return if (absolute.endsWith("/")) absolute + fileName else absolute
    }

    companion object {
        /** The largest file Fleet pushes: the phone keeps a copy until the cards are cleared. */
        const val MAX_BYTES = 100L * 1024 * 1024

        /** Whether [destination] can be a path: one line, with no NUL. */
        fun validDestination(destination: String): Boolean = destination.none { it == '\u0000' || it == '\n' || it == '\r' }

        /** Copies [input] to [output] and returns the bytes copied, or -1 as soon as there are more than [max]. */
        fun copyAtMost(input: InputStream, output: OutputStream, max: Long): Long {
            val buffer = ByteArray(64 * 1024)
            var total = 0L
            while (true) {
                val read = input.read(buffer)
                if (read < 0) return total
                total += read
                if (total > max) return -1
                output.write(buffer, 0, read)
            }
        }
    }
}
