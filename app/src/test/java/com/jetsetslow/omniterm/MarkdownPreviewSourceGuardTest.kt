package com.jetsetslow.omniterm

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * The Markdown preview cannot reach the network or open anything by itself, checked in its source:
 * it imports only Compose, Material 3, coroutines, the parser and the app's own highlighter, and
 * names no image loader, web view, socket, URL handler or intent. Links leave the preview through
 * its `onOpenLink` callback only, which the link question calls after the user chose Open.
 */
class MarkdownPreviewSourceGuardTest {

    private val dir: File = generateSequence(File("").absoluteFile) { it.parentFile }
        .map { File(it, "app/src/main/java/com/jetsetslow/omniterm/ui/markdown") }
        .firstOrNull { it.isDirectory }
        ?: error("the Markdown preview's sources were not found")

    private val sources: Map<String, String> = dir.listFiles { f -> f.extension == "kt" }!!.associate { it.name to it.readText() }

    private val allowedImports = listOf(
        "androidx.compose.foundation.",
        "androidx.compose.material3.",
        "androidx.compose.runtime.",
        "androidx.compose.ui.",
        "com.jetsetslow.omniterm.R",
        "com.jetsetslow.omniterm.ui.",
        "kotlinx.coroutines.",
        "org.intellij.markdown.",
        "kotlin.",
    )

    /** Ways a page loads or opens something: none of them may appear in the preview. */
    private val forbidden = listOf(
        "coil", "AsyncImage", "ImageLoader", "ImageRequest", "rememberAsyncImagePainter", "BitmapFactory",
        "java.net", "URL(", "URI(", "okhttp", "OkHttp", "HttpURLConnection", "Socket", "ktor",
        "WebView", "android.webkit", "fromHtml", "HtmlCompat", "Html.",
        "UriHandler", "LocalUriHandler", "LinkAnnotation.Url", "openUri",
        "Intent", "startActivity", "android.net", "LocalContext", "openLink", "CustomTabs",
        "org.intellij.markdown.html", "HtmlGenerator",
    )

    @Test
    fun thePreviewImportsNothingThatLoadsOrOpens() {
        assertEquals(setOf("MarkdownDocument.kt", "MarkdownPreview.kt"), sources.keys)
        for ((name, text) in sources) {
            val imports = Regex("(?m)^import\\s+(\\S+)").findAll(text).map { it.groupValues[1] }.toList()
            assertTrue("$name imports nothing", imports.isNotEmpty())
            for (imported in imports) {
                assertTrue("$name imports $imported", allowedImports.any { imported.startsWith(it) })
            }
            // Entities is a table of character names; the HTML generator itself is never used.
            val code = text.replace("org.intellij.markdown.html.entities.Entities", "")
            for (word in forbidden) {
                assertTrue("$name mentions $word", !code.contains(word))
            }
        }
    }

    @Test
    fun aLinkIsOnlyEverReportedNeverOpened() {
        val preview = sources.getValue("MarkdownPreview.kt")
        // The text's links only report a tap; the one call of onOpenLink is the question's Open.
        assertEquals(1, Regex("LinkAnnotation\\.Clickable\\(").findAll(preview).count())
        assertEquals(1, Regex("onOpenLink\\(").findAll(preview).count())
        assertTrue(Regex("onOpen = \\{\\s*question = null\\s*onOpenLink\\(url\\)").containsMatchIn(preview))
        // The parse never runs on the caller's thread: the preview goes through loadMarkdownPreview.
        assertTrue(preview.contains("loadMarkdownPreview("))
        assertTrue(!preview.contains("buildMarkdownPreview("))
    }
}
