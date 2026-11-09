package com.jetsetslow.omniterm

import android.content.Context
import androidx.test.core.app.ApplicationProvider
import com.jetsetslow.omniterm.ui.toolsItems
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import java.io.File

/**
 * Text that sends the user to "Tools → …" must name a Tools tile as it is labelled. The health
 * score pop-up pointed at "Tools → Settings → Health scoring", which does not exist, and the README
 * at "Tools → Backups Hub" and "Tools → Wake on LAN".
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class ToolsPathTextRobolectricTest {

    @Test
    fun `every Tools path names a Tools tile`() {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val labels = toolsItems.map { it.second }
        val paths = R.string::class.java.fields.mapNotNull { field ->
            val text = context.getString(field.getInt(null))
            text.substringAfter("Tools ", "").takeIf { it.isNotEmpty() }?.let { field.name to it }
        }
        assertEquals("strings that name a Tools path", 9, paths.size)
        // A deeper level would name a section inside a tile, which this check cannot see.
        paths.forEach { (name, path) ->
            assertTrue(
                "$name: \"Tools $path\" names no Tools tile, or goes past one",
                labels.any { path.startsWith("→ $it") && !path.startsWith("→ $it →") },
            )
        }
    }

    @Test
    fun `every Tools path in the README names a Tools tile`() {
        val readme = generateSequence(File("").absoluteFile) { it.parentFile }
            .map { File(it, "README.md") }
            .first { it.isFile }
        val labels = toolsItems.map { it.second }
        val paths = Regex("""\*\*Tools → ([^*]+)\*\*""").findAll(readme.readText()).map { it.groupValues[1] }.toList()
        assertTrue("the README names Tools paths", paths.size >= 5)
        // The README may go on into a tile's own tabs and sections.
        paths.forEach { path ->
            assertTrue("README: \"Tools → $path\" names no Tools tile", labels.any { path == it || path.startsWith("$it →") })
        }
    }
}
