package com.jetsetslow.omniterm.ui.markdown

import com.jetsetslow.omniterm.ui.CodeLanguage
import com.jetsetslow.omniterm.ui.HIGHLIGHT_MAX_CHARS_DEFAULT
import com.jetsetslow.omniterm.ui.HiToken
import com.jetsetslow.omniterm.ui.clampHighlightLimit
import com.jetsetslow.omniterm.ui.highlightAll
import com.jetsetslow.omniterm.ui.languageForFenceInfo
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.withContext
import org.intellij.markdown.IElementType
import org.intellij.markdown.MarkdownElementTypes
import org.intellij.markdown.MarkdownTokenTypes
import org.intellij.markdown.ast.ASTNode
import org.intellij.markdown.flavours.gfm.GFMElementTypes
import org.intellij.markdown.flavours.gfm.GFMFlavourDescriptor
import org.intellij.markdown.flavours.gfm.GFMTokenTypes
import org.intellij.markdown.html.entities.Entities
import org.intellij.markdown.parser.CancellationToken
import org.intellij.markdown.parser.MarkdownParser
import kotlin.coroutines.CoroutineContext
import kotlin.coroutines.cancellation.CancellationException
import kotlin.time.Duration.Companion.milliseconds
import kotlin.time.TimeSource

/*
 * The Markdown preview's model: JetBrains' parser (org.jetbrains:markdown, GFM flavour) reads the
 * text, and this file turns its tree into a flat list of blocks the preview draws one by one.
 *
 * Plain Kotlin on purpose (no Android or Compose types), so the iOS build can use it as it is.
 *
 * What the model never holds is as important as what it does:
 * - an image is its alt text and a marker; its address is never read, so nothing can load it;
 * - raw HTML is text;
 * - a link is a link only for http, https and mailto (and `#heading` in the same file); every other
 *   address, javascript:, file:, content:, intent:, data: and relative paths among them, leaves its
 *   text as plain text.
 *
 * Nesting becomes numbers (list levels, quote levels) on flat blocks, and every walk over the
 * parser's tree keeps its own stack, so a file nested thousands of levels deep cannot overflow the
 * thread's stack. Long paragraphs and code blocks are cut into pieces the preview lays out one at a
 * time.
 */

/** Above this many characters the preview says the file is too large and parses nothing. */
const val MARKDOWN_PREVIEW_MAX_CHARS = 200_000

/** Parsing and building give up after this long, for input the parser is slow on. */
const val MARKDOWN_PREVIEW_BUDGET_MS = 8_000L

/**
 * A line opens at most this many quotes and list items of its own; markers past them read as text.
 * The parser's time and memory grow with the square of one line's nesting (20,000 `>` on a line ran
 * it out of memory), while real files nest a few levels.
 */
internal const val MAX_MARKERS_PER_LINE = 32

/** A table shows at most this many columns; the preview says how many more there are. */
internal const val MAX_TABLE_COLUMNS = 30

/** A table cell, heading or link address shows at most this many characters. */
internal const val MAX_CELL_CHARS = 1_000
internal const val MAX_URL_CHARS = 2_048

/** A paragraph or a code block is drawn in pieces of at most this many characters... */
internal const val CHUNK_CHARS = 4_000

/** ...and a code block's pieces hold at most this many lines. */
internal const val CODE_CHUNK_LINES = 60

/** Where a link in the preview may lead. Anything else is not a link: its text shows as plain text. */
sealed interface MdLink {
    /** An http, https or mailto address, opened only after the user has seen it in full and agreed. */
    data class External(val url: String) : MdLink

    /** A heading in this file (`#install`), by its slug. */
    data class Anchor(val slug: String) : MdLink
}

enum class MdStyle { BOLD, ITALIC, STRIKE, CODE, LINK, IMAGE, HTML }

/** A style over [start, end) of an [MdText]; [link] is set for [MdStyle.LINK]. */
data class MdSpan(val start: Int, val end: Int, val style: MdStyle, val link: MdLink? = null)

/** Text and its inline styles. */
data class MdText(val text: String, val spans: List<MdSpan> = emptyList())

/**
 * How deep a block sits: inside [lists] list items and [quotes] block quotes. [marker] is the list
 * marker drawn before it (•, 3., ☐, ☑), on the first block of an item only.
 */
data class MdNesting(val lists: Int = 0, val quotes: Int = 0, val marker: String? = null)

enum class MdAlign { START, CENTER, END }

/** One table's shape, shared by its rows: the columns shown, their widths in characters and how many more there are. */
class MdTable(val alignments: List<MdAlign>, val widths: List<Int>, val hiddenColumns: Int)

sealed interface MdBlock {
    val nesting: MdNesting
}

data class MdHeading(val level: Int, val text: MdText, val anchor: String, override val nesting: MdNesting) : MdBlock

/** [continued]: the rest of a paragraph too long to lay out at once. */
data class MdParagraph(val text: MdText, override val nesting: MdNesting, val continued: Boolean = false) : MdBlock

/**
 * A piece of a code block: its text, coloured by [tokens] from the editor's highlighter. [first] and
 * [last] say where the block starts and ends. [html]: raw HTML, which is shown as it is written.
 */
data class MdCode(
    val text: String,
    val tokens: List<HiToken>,
    override val nesting: MdNesting,
    val first: Boolean = true,
    val last: Boolean = true,
    val html: Boolean = false,
) : MdBlock

data class MdTableRow(
    val table: MdTable,
    val cells: List<MdText>,
    val header: Boolean,
    override val nesting: MdNesting,
    val first: Boolean,
) : MdBlock

data class MdRule(override val nesting: MdNesting) : MdBlock

/** The blocks to draw, and where each heading's anchor is among them. */
class MdDocument(val blocks: List<MdBlock>, val anchors: Map<String, Int>)

sealed interface MarkdownPreviewResult {
    data class Ready(val document: MdDocument) : MarkdownPreviewResult

    /** The file is longer than [limit] characters; nothing was parsed. */
    data class TooLarge(val chars: Int, val limit: Int) : MarkdownPreviewResult

    /** Parsing took longer than its budget. */
    data object TooSlow : MarkdownPreviewResult

    /** The parser failed on this text. */
    data object Unreadable : MarkdownPreviewResult
}

/**
 * The preview of [text], built on [background] (never the caller's thread) and abandoned as soon as
 * the caller is cancelled.
 */
suspend fun loadMarkdownPreview(
    text: String,
    imageMarker: String,
    highlightMaxChars: Int = HIGHLIGHT_MAX_CHARS_DEFAULT,
    background: CoroutineContext = Dispatchers.Default,
): MarkdownPreviewResult = withContext(background) {
    val job = coroutineContext[Job]
    buildMarkdownPreview(text, imageMarker, highlightMaxChars, isActive = { job?.isActive != false })
}

/**
 * The preview of [text]. [imageMarker] is shown in place of every image. Gives up with
 * [MarkdownPreviewResult.TooSlow] after [budgetMs], and throws [CancellationException] as soon as
 * [isActive] turns false.
 */
fun buildMarkdownPreview(
    text: String,
    imageMarker: String,
    highlightMaxChars: Int = HIGHLIGHT_MAX_CHARS_DEFAULT,
    budgetMs: Long = MARKDOWN_PREVIEW_BUDGET_MS,
    isActive: () -> Boolean = { true },
): MarkdownPreviewResult {
    if (text.length > MARKDOWN_PREVIEW_MAX_CHARS) return MarkdownPreviewResult.TooLarge(text.length, MARKDOWN_PREVIEW_MAX_CHARS)
    val deadline = TimeSource.Monotonic.markNow() + budgetMs.milliseconds
    val check = CancellationToken {
        if (!isActive()) throw CancellationException("The preview is no longer shown")
        if (deadline.hasPassedNow()) throw OutOfBudget()
    }
    return try {
        check.checkCancelled()
        val source = limitNesting(text)
        val root = MarkdownParser(GFMFlavourDescriptor(), assertionsEnabled = false, cancellationToken = check)
            .buildMarkdownTreeFromString(source)
        MarkdownPreviewResult.Ready(DocumentBuilder(source, imageMarker, highlightMaxChars, check).build(root))
    } catch (e: OutOfBudget) {
        MarkdownPreviewResult.TooSlow
    } catch (e: CancellationException) {
        throw e
    } catch (e: RuntimeException) {
        MarkdownPreviewResult.Unreadable
    } catch (e: StackOverflowError) {
        // Every walk here keeps its own stack; this is for one inside the parser, should it have one.
        MarkdownPreviewResult.Unreadable
    }
}

/**
 * [text] with each line's quote and list markers past the [MAX_MARKERS_PER_LINE]th escaped, so the
 * rest of the line reads as text. Lines within the limit, nearly every line of nearly every file,
 * are left exactly as they are.
 */
internal fun limitNesting(text: String): String {
    var out: StringBuilder? = null
    var copied = 0
    var lineStart = 0
    while (lineStart <= text.length) {
        val lineEnd = text.indexOf('\n', lineStart).let { if (it < 0) text.length else it }
        var i = lineStart
        var markers = 0
        while (i < lineEnd) {
            while (i < lineEnd && (text[i] == ' ' || text[i] == '\t')) i++
            if (i >= lineEnd) break
            // Where the marker starts, where a backslash makes it text, and where it ends.
            val c = text[i]
            var escapeAt = i
            val end = when {
                c == '>' -> i + 1
                (c == '-' || c == '*' || c == '+') && isSpaceAt(text, i + 1, lineEnd) -> i + 1
                c.isDigit() -> {
                    var j = i
                    while (j < lineEnd && j - i < 9 && text[j].isDigit()) j++
                    escapeAt = j
                    if (j < lineEnd && (text[j] == '.' || text[j] == ')') && isSpaceAt(text, j + 1, lineEnd)) j + 1 else -1
                }
                else -> -1
            }
            if (end < 0) break
            if (++markers > MAX_MARKERS_PER_LINE) {
                val builder = out ?: StringBuilder(text.length + 16).also { out = it }
                builder.append(text, copied, escapeAt).append('\\')
                copied = escapeAt
                break
            }
            i = end
        }
        lineStart = lineEnd + 1
    }
    return out?.append(text, copied, text.length)?.toString() ?: text
}

private fun isSpaceAt(text: String, at: Int, end: Int): Boolean = at < end && (text[at] == ' ' || text[at] == '\t')

private class OutOfBudget : RuntimeException("The Markdown preview ran out of time")

private val BULLETS = listOf("•", "◦", "▪")

/** Turns the parser's tree into [MdBlock]s. Every walk keeps its own stack. */
private class DocumentBuilder(
    private val src: String,
    private val imageMarker: String,
    highlightMaxChars: Int,
    private val check: CancellationToken,
) {
    private val highlightLimit = clampHighlightLimit(highlightMaxChars)
    private val blocks = ArrayList<MdBlock>()
    private val anchors = HashMap<String, Int>()
    private val slugUses = HashMap<String, Int>()
    private val definitions = HashMap<String, String>()

    /** The marker of the list item whose first block is still to come, and where that item sits. */
    private class Pending(val marker: String, val lists: Int, val quotes: Int)

    private var pending: Pending? = null

    private class ListCount(val ordered: Boolean, var next: Long, val delimiter: Char)

    private class Frame(val node: ASTNode, val lists: Int, val quotes: Int, val list: ListCount?) {
        var next = 0
    }

    fun build(root: ASTNode): MdDocument {
        collectDefinitions(root)
        walk(root)
        return MdDocument(blocks, anchors)
    }

    private fun textOf(node: ASTNode): String = src.substring(node.startOffset, node.endOffset)

    private fun ASTNode.child(type: IElementType): ASTNode? = children.firstOrNull { it.type == type }

    /** Reference link definitions (`[label]: address`), which may come after their uses. */
    private fun collectDefinitions(root: ASTNode) {
        val stack = ArrayDeque<ASTNode>()
        stack.addLast(root)
        while (stack.isNotEmpty()) {
            check.checkCancelled()
            val node = stack.removeLast()
            when (node.type) {
                MarkdownElementTypes.LINK_DEFINITION -> {
                    val label = node.child(MarkdownElementTypes.LINK_LABEL) ?: continue
                    val destination = node.child(MarkdownElementTypes.LINK_DESTINATION) ?: continue
                    definitions.getOrPut(labelKey(textOf(label))) { destination(textOf(destination)) }
                }
                in NO_DEFINITIONS_INSIDE -> {}
                else -> node.children.forEach { stack.addLast(it) }
            }
        }
    }

    private fun walk(root: ASTNode) {
        val stack = ArrayDeque<Frame>()
        stack.addLast(Frame(root, 0, 0, null))
        while (stack.isNotEmpty()) {
            check.checkCancelled()
            val frame = stack.last()
            val children = frame.node.children
            if (frame.next >= children.size) {
                stack.removeLast()
                // An item with nothing in it still shows its marker.
                if (frame.node.type == MarkdownElementTypes.LIST_ITEM) flushMarker()
                continue
            }
            val child = children[frame.next++]
            when (child.type) {
                MarkdownElementTypes.BLOCK_QUOTE, GFMElementTypes.ALERT ->
                    stack.addLast(Frame(child, frame.lists, frame.quotes + 1, null))
                MarkdownElementTypes.UNORDERED_LIST, MarkdownElementTypes.ORDERED_LIST ->
                    stack.addLast(Frame(child, frame.lists + 1, frame.quotes, listCount(child)))
                MarkdownElementTypes.LIST_ITEM -> {
                    // An item whose first block is another item: the outer marker gets a line of its own.
                    flushMarker()
                    pending = Pending(marker(child, frame), frame.lists, frame.quotes)
                    stack.addLast(Frame(child, frame.lists, frame.quotes, null))
                }
                MarkdownElementTypes.PARAGRAPH -> paragraph(inline(child), frame)
                MarkdownElementTypes.ATX_1, MarkdownElementTypes.ATX_2, MarkdownElementTypes.ATX_3,
                MarkdownElementTypes.ATX_4, MarkdownElementTypes.ATX_5, MarkdownElementTypes.ATX_6 ->
                    heading(ATX_LEVELS.getValue(child.type), child.child(MarkdownTokenTypes.ATX_CONTENT), frame)
                MarkdownElementTypes.SETEXT_1 -> heading(1, child.child(MarkdownTokenTypes.SETEXT_CONTENT), frame)
                MarkdownElementTypes.SETEXT_2 -> heading(2, child.child(MarkdownTokenTypes.SETEXT_CONTENT), frame)
                MarkdownElementTypes.CODE_FENCE -> fence(child, frame)
                MarkdownElementTypes.CODE_BLOCK -> indentedCode(child, frame)
                MarkdownElementTypes.HTML_BLOCK -> html(child, frame)
                GFMElementTypes.TABLE -> table(child, frame)
                GFMElementTypes.BLOCK_MATH -> code(textOf(child).trim().removeSurrounding("$$").trim('\n'), CodeLanguage.NONE, frame)
                MarkdownTokenTypes.HORIZONTAL_RULE -> blocks += MdRule(nesting(frame))
                GFMTokenTypes.ALERT_TITLE -> {
                    val title = textOf(child).trim().removePrefix("[!").removeSuffix("]").lowercase().replaceFirstChar { it.uppercaseChar() }
                    paragraph(MdText(title, listOf(MdSpan(0, title.length, MdStyle.BOLD))), frame)
                }
                MarkdownElementTypes.LINK_DEFINITION -> {}
                else -> if (child.children.isNotEmpty() && child.type !in NOT_BLOCKS) {
                    stack.addLast(Frame(child, frame.lists, frame.quotes, null))
                }
            }
        }
        flushMarker()
    }

    /** The nesting of a new block in [frame], with the pending list marker if this is its item's first block. */
    private fun nesting(frame: Frame): MdNesting {
        val marker = pending?.marker
        pending = null
        return MdNesting(frame.lists, frame.quotes, marker)
    }

    /** The pending marker on an empty line of its own, where its item sits. */
    private fun flushMarker() {
        val p = pending ?: return
        pending = null
        blocks += MdParagraph(MdText(""), MdNesting(p.lists, p.quotes, p.marker))
    }

    private fun listCount(list: ASTNode): ListCount {
        if (list.type != MarkdownElementTypes.ORDERED_LIST) return ListCount(false, 0, ' ')
        val number = list.child(MarkdownElementTypes.LIST_ITEM)?.child(MarkdownTokenTypes.LIST_NUMBER)?.let { textOf(it).trim() }.orEmpty()
        val start = number.takeWhile { it.isDigit() }.take(9).toLongOrNull() ?: 1
        return ListCount(true, start, number.lastOrNull()?.takeIf { it == '.' || it == ')' } ?: '.')
    }

    private fun marker(item: ASTNode, frame: Frame): String {
        item.child(GFMTokenTypes.CHECK_BOX)?.let { box ->
            val text = textOf(box).trim()
            return if (text.length > 1 && text[1] != ' ') "☑" else "☐"
        }
        val list = frame.list
        if (list != null && list.ordered) return "${list.next++}${list.delimiter}"
        return BULLETS[(frame.lists - 1).coerceAtLeast(0) % BULLETS.size]
    }

    private fun paragraph(text: MdText, frame: Frame) {
        val pieces = text.chunked(CHUNK_CHARS)
        blocks += MdParagraph(pieces.first(), nesting(frame))
        for (piece in pieces.drop(1)) blocks += MdParagraph(piece, MdNesting(frame.lists, frame.quotes), continued = true)
    }

    private fun heading(level: Int, content: ASTNode?, frame: Frame) {
        val text = (content?.let { inline(it) } ?: MdText("")).limited(MAX_CELL_CHARS)
        val base = headingSlug(text.text)
        val uses = slugUses[base] ?: 0
        slugUses[base] = uses + 1
        val slug = if (uses == 0) base else "$base-$uses"
        anchors.getOrPut(slug) { blocks.size }
        blocks += MdHeading(level, text, slug, nesting(frame))
    }

    private fun fence(node: ASTNode, frame: Frame) {
        // Lines lose as much indentation as the opening fence had, as CommonMark says.
        val indent = textOf(node).takeWhile { it == ' ' }.length
        var info = ""
        var inBody = false
        val body = StringBuilder()
        for (child in node.children) {
            when {
                !inBody && child.type == MarkdownTokenTypes.FENCE_LANG -> info = textOf(child).trim()
                !inBody && child.type == MarkdownTokenTypes.EOL -> inBody = true
                inBody && child.type == MarkdownTokenTypes.CODE_FENCE_CONTENT -> body.append(dropIndent(textOf(child), indent))
                inBody && child.type == MarkdownTokenTypes.EOL -> body.append('\n')
            }
        }
        code(body.removeSuffix("\n").toString(), languageForFenceInfo(unescapeMarkdown(info)), frame)
    }

    private fun indentedCode(node: ASTNode, frame: Frame) {
        val body = StringBuilder()
        for (child in node.children) {
            when (child.type) {
                MarkdownTokenTypes.CODE_LINE -> body.append(dropIndent(textOf(child), 4))
                MarkdownTokenTypes.EOL -> body.append('\n')
            }
        }
        code(body.trimEnd('\n').toString(), CodeLanguage.NONE, frame)
    }

    /** Raw HTML, kept exactly as written and shown as text: nothing in it is interpreted. */
    private fun html(node: ASTNode, frame: Frame) {
        val body = StringBuilder()
        for (child in node.children) {
            when (child.type) {
                MarkdownTokenTypes.HTML_BLOCK_CONTENT -> body.append(textOf(child))
                MarkdownTokenTypes.EOL -> body.append('\n')
            }
        }
        code(body.trimEnd('\n').toString(), CodeLanguage.NONE, frame, html = true)
    }

    private fun code(text: String, language: CodeLanguage, frame: Frame, html: Boolean = false) {
        val tokens = if (language != CodeLanguage.NONE && text.length <= highlightLimit) highlightAll(text, language) else emptyList()
        val nesting = nesting(frame)
        if (text.isEmpty()) {
            blocks += MdCode("", emptyList(), nesting, html = html)
            return
        }
        var start = 0
        var token = 0
        while (start < text.length) {
            check.checkCancelled()
            val end = codeChunkEnd(text, start)
            // Tokens never cross a line, so a piece cut at a line end takes whole tokens.
            while (token < tokens.size && tokens[token].end <= start) token++
            val pieceTokens = ArrayList<HiToken>()
            var t = token
            while (t < tokens.size && tokens[t].start < end) {
                val from = maxOf(tokens[t].start, start)
                val to = minOf(tokens[t].end, end)
                if (from < to) pieceTokens += HiToken(from - start, to - start, tokens[t].kind)
                t++
            }
            val piece = text.substring(start, end)
            blocks += MdCode(
                text = piece.removeSuffix("\n"),
                tokens = pieceTokens,
                nesting = if (start == 0) nesting else MdNesting(frame.lists, frame.quotes),
                first = start == 0,
                last = end >= text.length,
                html = html,
            )
            start = end
        }
    }

    private fun table(node: ASTNode, frame: Frame) {
        val rows = node.children.filter { it.type == GFMElementTypes.HEADER || it.type == GFMElementTypes.ROW }
        val header = rows.firstOrNull { it.type == GFMElementTypes.HEADER }
        if (header == null) {
            paragraph(MdText(textOf(node)), frame)
            return
        }
        val columns = header.children.count { it.type == GFMTokenTypes.CELL }.coerceAtLeast(1)
        val shown = minOf(columns, MAX_TABLE_COLUMNS)
        val separator = node.children.firstOrNull { it.type == GFMTokenTypes.TABLE_SEPARATOR }?.let { textOf(it) }.orEmpty()
        val alignments = alignments(separator).let { found -> List(shown) { found.getOrNull(it) ?: MdAlign.START } }
        val cells = ArrayList<List<MdText>>(rows.size)
        val widths = IntArray(shown) { 3 }
        for (row in rows) {
            check.checkCancelled()
            val texts = ArrayList<MdText>(shown)
            for (cell in row.children) {
                if (cell.type != GFMTokenTypes.CELL) continue
                if (texts.size == shown) break
                texts += inline(cell, inCell = true).limited(MAX_CELL_CHARS)
            }
            while (texts.size < shown) texts += MdText("")
            texts.forEachIndexed { i, t -> widths[i] = maxOf(widths[i], minOf(t.text.length, MAX_COLUMN_CHARS)) }
            cells += texts
        }
        val table = MdTable(alignments, widths.toList(), columns - shown)
        rows.forEachIndexed { i, row ->
            blocks += MdTableRow(
                table = table,
                cells = cells[i],
                header = row.type == GFMElementTypes.HEADER,
                nesting = if (i == 0) nesting(frame) else MdNesting(frame.lists, frame.quotes),
                first = i == 0,
            )
        }
    }

    private fun alignments(separator: String): List<MdAlign> {
        val parts = separator.split('|')
        return parts.filterIndexed { i, part -> part.isNotBlank() || i in 1 until parts.lastIndex }.map {
            val cell = it.trim()
            when {
                cell.startsWith(':') && cell.endsWith(':') && cell.length > 1 -> MdAlign.CENTER
                cell.endsWith(':') -> MdAlign.END
                else -> MdAlign.START
            }
        }
    }

    /** An open inline container while [inline] walks: the children left and the style to close it with. */
    private class Open(
        val children: List<ASTNode>,
        var next: Int,
        val end: Int,
        val style: MdStyle?,
        val link: MdLink?,
        val start: Int,
    )

    /** Inline content of [node] as text and spans. */
    private fun inline(node: ASTNode, inCell: Boolean = false): MdText {
        val out = StringBuilder()
        val spans = ArrayList<MdSpan>()
        val stack = ArrayDeque<Open>()
        var links = 0
        fun open(children: List<ASTNode>, from: Int, to: Int, style: MdStyle? = null, link: MdLink? = null) {
            if (link != null) links++
            stack.addLast(Open(children, from, maxOf(from, to), style, link, out.length))
        }
        fun styled(text: String, style: MdStyle, link: MdLink? = null) {
            val start = out.length
            out.append(text)
            if (out.length > start) spans += MdSpan(start, out.length, style, link)
        }
        fun space() {
            if (out.isNotEmpty() && out.last() != ' ' && out.last() != '\n') out.append(' ')
        }
        open(node.children, 0, node.children.size)
        while (stack.isNotEmpty()) {
            check.checkCancelled()
            val top = stack.last()
            if (top.next >= top.end) {
                stack.removeLast()
                if (top.link != null) links--
                if (top.style != null && out.length > top.start) spans += MdSpan(top.start, out.length, top.style, top.link)
                continue
            }
            val index = top.next++
            val child = top.children[index]
            val kids = child.children
            when (child.type) {
                MarkdownElementTypes.EMPH -> open(kids, 1, kids.size - 1, MdStyle.ITALIC)
                MarkdownElementTypes.STRONG -> open(kids, 2, kids.size - 2, MdStyle.BOLD)
                GFMElementTypes.STRIKETHROUGH -> {
                    val (from, to) = trimEqualDelimiters(kids, GFMTokenTypes.TILDE)
                    open(kids, from, to, MdStyle.STRIKE)
                }
                GFMElementTypes.HIGHLIGHT -> {
                    val (from, to) = trimEqualDelimiters(kids, GFMTokenTypes.EQUALS)
                    open(kids, from, to, MdStyle.BOLD)
                }
                MarkdownElementTypes.CODE_SPAN, GFMElementTypes.INLINE_MATH -> styled(codeSpan(child, inCell), MdStyle.CODE)
                MarkdownElementTypes.INLINE_LINK -> {
                    val label = child.child(MarkdownElementTypes.LINK_TEXT)
                    if (label == null) {
                        open(kids, 0, kids.size)
                    } else {
                        val target = child.child(MarkdownElementTypes.LINK_DESTINATION)?.let { linkTarget(destination(textOf(it))) }
                        val labelKids = label.children
                        open(labelKids, 1, labelKids.size - 1, if (target != null && links == 0) MdStyle.LINK else null, target.takeIf { links == 0 })
                    }
                }
                MarkdownElementTypes.FULL_REFERENCE_LINK, MarkdownElementTypes.SHORT_REFERENCE_LINK -> {
                    val label = child.child(MarkdownElementTypes.LINK_LABEL)
                    val address = label?.let { definitions[labelKey(textOf(it))] }
                    if (address == null) {
                        open(kids, 0, kids.size)
                    } else {
                        val target = linkTarget(address).takeIf { links == 0 }
                        val shownKids = (child.child(MarkdownElementTypes.LINK_TEXT) ?: label).children
                        open(shownKids, 1, shownKids.size - 1, if (target != null) MdStyle.LINK else null, target)
                    }
                }
                MarkdownElementTypes.IMAGE -> image(child, out, spans)
                MarkdownElementTypes.AUTOLINK -> {
                    val shown = textOf(child).removePrefix("<").removeSuffix(">")
                    val target = linkTarget(autolinkAddress(shown)).takeIf { links == 0 }
                    if (target != null) styled(shown, MdStyle.LINK, target) else out.append(shown)
                }
                GFMTokenTypes.GFM_AUTOLINK -> {
                    val shown = textOf(child)
                    val target = linkTarget(autolinkAddress(shown)).takeIf { links == 0 }
                    if (target != null) styled(shown, MdStyle.LINK, target) else out.append(shown)
                }
                MarkdownTokenTypes.EMAIL_AUTOLINK -> {
                    val shown = textOf(child)
                    val target = linkTarget("mailto:$shown").takeIf { links == 0 }
                    if (target != null) styled(shown, MdStyle.LINK, target) else out.append(shown)
                }
                // The brackets around an e-mail autolink are not shown.
                MarkdownTokenTypes.LT -> if (top.children.getOrNull(index + 1)?.type != MarkdownTokenTypes.EMAIL_AUTOLINK) out.append('<')
                MarkdownTokenTypes.GT -> if (top.children.getOrNull(index - 1)?.type != MarkdownTokenTypes.EMAIL_AUTOLINK) out.append('>')
                // Raw HTML stays text, exactly as written.
                MarkdownTokenTypes.HTML_TAG -> styled(textOf(child), MdStyle.HTML)
                MarkdownTokenTypes.HARD_LINE_BREAK -> out.append('\n')
                MarkdownTokenTypes.EOL -> space()
                MarkdownTokenTypes.WHITE_SPACE -> if (top.children.getOrNull(index - 1)?.type != MarkdownTokenTypes.EOL) space()
                // Quote markers of lazy continuation lines, and a task item's box (drawn as its marker).
                MarkdownTokenTypes.BLOCK_QUOTE, GFMTokenTypes.CHECK_BOX -> {}
                else -> if (kids.isEmpty()) {
                    val leaf = textOf(child)
                    out.append(if (inCell) unescapeMarkdown(leaf.replace("\\|", "|")) else unescapeMarkdown(leaf))
                } else {
                    open(kids, 0, kids.size)
                }
            }
        }
        return MdText(out.toString(), spans).trimmed()
    }

    /** A code span's text: as written, line ends as spaces, one space of padding each side removed. */
    private fun codeSpan(node: ASTNode, inCell: Boolean): String {
        val kids = node.children
        val raw = buildString {
            for (k in 1 until kids.size - 1) {
                if (kids[k].type != MarkdownTokenTypes.BLOCK_QUOTE) append(textOf(kids[k]))
            }
        }.replace("\r\n", " ").replace('\n', ' ').let { if (inCell) it.replace("\\|", "|") else it }
        return if (raw.length >= 2 && raw.first() == ' ' && raw.last() == ' ' && raw.isNotBlank()) raw.substring(1, raw.length - 1) else raw
    }

    /**
     * An image: its alt text and [imageMarker]. Its address is never read, so nothing can fetch it,
     * and an image inside a link takes that link's question like any other text.
     */
    private fun image(node: ASTNode, out: StringBuilder, spans: MutableList<MdSpan>) {
        val link = node.child(MarkdownElementTypes.INLINE_LINK)
            ?: node.child(MarkdownElementTypes.FULL_REFERENCE_LINK)
            ?: node.child(MarkdownElementTypes.SHORT_REFERENCE_LINK)
        val label = link?.let { it.child(MarkdownElementTypes.LINK_TEXT) ?: it.child(MarkdownElementTypes.LINK_LABEL) }
        val alt = label?.let { altText(it) }.orEmpty().trim().take(MAX_CELL_CHARS)
        if (alt.isNotEmpty()) {
            out.append(alt).append(' ')
        }
        val start = out.length
        out.append(imageMarker)
        spans += MdSpan(start, out.length, MdStyle.IMAGE)
    }

    /** The words of an image's label, without markup or any address inside it. */
    private fun altText(label: ASTNode): String {
        val out = StringBuilder()
        val stack = ArrayDeque<ASTNode>()
        label.children.asReversed().forEach { stack.addLast(it) }
        while (stack.isNotEmpty()) {
            check.checkCancelled()
            val node = stack.removeLast()
            when {
                node.type in ALT_SKIPPED -> {}
                node.children.isEmpty() -> out.append(if (node.type == MarkdownTokenTypes.EOL) " " else unescapeMarkdown(textOf(node)))
                else -> node.children.asReversed().forEach { stack.addLast(it) }
            }
        }
        return out.toString()
    }

    private companion object {
        val ATX_LEVELS = mapOf(
            MarkdownElementTypes.ATX_1 to 1, MarkdownElementTypes.ATX_2 to 2, MarkdownElementTypes.ATX_3 to 3,
            MarkdownElementTypes.ATX_4 to 4, MarkdownElementTypes.ATX_5 to 5, MarkdownElementTypes.ATX_6 to 6,
        )

        /** Blocks that hold inline content or text only: no link definitions, nothing to walk into. */
        val NO_DEFINITIONS_INSIDE = setOf(
            MarkdownElementTypes.PARAGRAPH, MarkdownElementTypes.CODE_FENCE, MarkdownElementTypes.CODE_BLOCK,
            MarkdownElementTypes.HTML_BLOCK, GFMElementTypes.TABLE, MarkdownElementTypes.ATX_1, MarkdownElementTypes.ATX_2,
            MarkdownElementTypes.ATX_3, MarkdownElementTypes.ATX_4, MarkdownElementTypes.ATX_5, MarkdownElementTypes.ATX_6,
            MarkdownElementTypes.SETEXT_1, MarkdownElementTypes.SETEXT_2,
        )

        /** Composite nodes the block walk does not enter. */
        val NOT_BLOCKS = setOf(MarkdownElementTypes.LINK_DEFINITION)

        /** Markup in an image label, and addresses and titles, which alt text never includes. */
        val ALT_SKIPPED = setOf(
            MarkdownTokenTypes.EMPH, MarkdownTokenTypes.BACKTICK, MarkdownTokenTypes.EXCLAMATION_MARK,
            MarkdownTokenTypes.LBRACKET, MarkdownTokenTypes.RBRACKET, MarkdownTokenTypes.LPAREN, MarkdownTokenTypes.RPAREN,
            MarkdownElementTypes.LINK_DESTINATION, MarkdownElementTypes.LINK_TITLE, MarkdownTokenTypes.BLOCK_QUOTE,
            GFMTokenTypes.TILDE,
        )

        /** A table column is at most this many characters wide; longer cells wrap. */
        const val MAX_COLUMN_CHARS = 40
    }
}

/** The first and last child index of [kids] inside an equal number of [delimiter]s at each end. */
private fun trimEqualDelimiters(kids: List<ASTNode>, delimiter: IElementType): Pair<Int, Int> {
    var left = 0
    var right = kids.size - 1
    while (left < right && kids[left].type == delimiter && kids[right].type == delimiter) {
        left++
        right--
    }
    return left to right + 1
}

private fun dropIndent(line: String, indent: Int): String {
    var i = 0
    while (i < indent && i < line.length && line[i] == ' ') i++
    return line.substring(i)
}

/** End of the piece of a code block from [start]: whole lines, at most [CODE_CHUNK_LINES] and [CHUNK_CHARS]. */
internal fun codeChunkEnd(text: String, start: Int): Int {
    var i = start
    var lines = 0
    while (lines < CODE_CHUNK_LINES && i < text.length) {
        val newline = text.indexOf('\n', i)
        val lineEnd = if (newline < 0) text.length else newline + 1
        if (lineEnd - start > CHUNK_CHARS) return if (i > start) i else safeCut(text, start + CHUNK_CHARS)
        i = lineEnd
        lines++
    }
    return i
}

/** [at], or one before it when that would split a surrogate pair. */
private fun safeCut(text: String, at: Int): Int = if (at in 1 until text.length && text[at - 1].isHighSurrogate()) at - 1 else at

/** [MdText] cut into pieces of at most [max] characters, at a space where there is one. */
internal fun MdText.chunked(max: Int): List<MdText> {
    if (text.length <= max) return listOf(this)
    val out = ArrayList<MdText>()
    var start = 0
    while (start < text.length) {
        var end = minOf(text.length, start + max)
        if (end < text.length) {
            val space = text.lastIndexOf(' ', end - 1)
            end = if (space > start + max / 2) space + 1 else safeCut(text, end)
        }
        out += slice(start, end)
        start = end
    }
    return out
}

internal fun MdText.slice(start: Int, end: Int): MdText = MdText(
    text.substring(start, end),
    spans.mapNotNull { span ->
        val from = maxOf(span.start, start)
        val to = minOf(span.end, end)
        if (from < to) span.copy(start = from - start, end = to - start) else null
    },
)

private fun MdText.trimmed(): MdText {
    var start = 0
    var end = text.length
    while (start < end && text[start].isWhitespace()) start++
    while (end > start && text[end - 1].isWhitespace()) end--
    return if (start == 0 && end == text.length) this else slice(start, end)
}

private fun MdText.limited(max: Int): MdText = if (text.length <= max) this else slice(0, safeCut(text, max)).let { it.copy(text = it.text + "…") }

/** A reference label as CommonMark matches it: case and runs of white space ignored. */
private fun labelKey(label: String): String = buildString {
    var space = false
    for (c in label.trim()) {
        if (c.isWhitespace()) {
            space = true
        } else {
            if (space && isNotEmpty()) append(' ')
            space = false
            append(c.lowercaseChar())
        }
    }
}

/** A link destination as written: without `<...>`, its escapes and entities decoded. */
private fun destination(raw: String): String = unescapeMarkdown(raw.trim().removeSurrounding("<", ">"))

/** The address a bare or `<...>` autolink stands for. */
private fun autolinkAddress(shown: String): String = when {
    shown.contains("://") || shown.startsWith("mailto:", ignoreCase = true) -> shown
    shown.startsWith("www.", ignoreCase = true) -> "https://$shown"
    '@' in shown && ':' !in shown -> "mailto:$shown"
    else -> shown
}

/**
 * Where [address] may lead from the preview. Only http and https addresses with a host, mailto
 * addresses and `#heading` anchors are links; anything else (javascript:, file:, content:, intent:,
 * data:, a relative path) is not, and an address with white space, control or invisible formatting
 * characters is not either, so what the question shows is what would open.
 */
fun linkTarget(address: String): MdLink? {
    val url = address.trim()
    if (url.isEmpty() || url.length > MAX_URL_CHARS) return null
    if (url.any { it.isWhitespace() || it.isISOControl() || it.category == CharCategory.FORMAT }) return null
    if (url.startsWith("#")) return url.substring(1).takeIf { it.isNotEmpty() }?.let { MdLink.Anchor(it.lowercase()) }
    val colon = url.indexOf(':')
    if (colon <= 0) return null
    val scheme = url.substring(0, colon)
    if (!scheme.all { it in 'a'..'z' || it in 'A'..'Z' }) return null
    return when (scheme.lowercase()) {
        "http", "https" -> MdLink.External(url).takeIf { url.startsWith("//", colon + 1) && url.length > colon + 3 }
        "mailto" -> MdLink.External(url).takeIf { url.length > colon + 1 }
        else -> null
    }
}

/** GitHub's anchor for a heading: lower case, letters, digits, `-` and `_` kept, spaces as `-`. */
internal fun headingSlug(text: String): String = buildString {
    for (c in text.lowercase()) {
        when {
            c.isLetterOrDigit() || c == '-' || c == '_' -> append(c)
            c == ' ' -> append('-')
        }
    }
}

private const val ESCAPABLE = "!\"#\$%&'()*+,-./:;<=>?@[\\]^_`{|}~"

/** Markdown text as it reads: backslash escapes and HTML character references decoded. */
internal fun unescapeMarkdown(text: String): String {
    if (text.indexOf('\\') < 0 && text.indexOf('&') < 0) return text
    val out = StringBuilder(text.length)
    var i = 0
    while (i < text.length) {
        val c = text[i]
        if (c == '\\' && i + 1 < text.length && text[i + 1] in ESCAPABLE) {
            out.append(text[i + 1])
            i += 2
            continue
        }
        if (c == '&') {
            val semicolon = text.indexOf(';', i + 1)
            if (semicolon in (i + 2)..(i + 33)) {
                val decoded = decodeEntity(text.substring(i, semicolon + 1))
                if (decoded != null) {
                    out.append(decoded)
                    i = semicolon + 1
                    continue
                }
            }
        }
        out.append(c)
        i++
    }
    return out.toString()
}

/** `&amp;`, `&#38;` or `&#x26;` as the character it stands for, or null when it is not one. */
private fun decodeEntity(entity: String): String? {
    val body = entity.substring(1, entity.length - 1)
    val code = when {
        body.startsWith("#x") || body.startsWith("#X") ->
            body.substring(2).takeIf { it.length in 1..6 && it.all { c -> c.isDigit() || c.lowercaseChar() in 'a'..'f' } }?.toInt(16)
        body.startsWith("#") -> body.substring(1).takeIf { it.length in 1..7 && it.all(Char::isDigit) }?.toInt()
        body.all { it.isLetterOrDigit() } -> Entities.map[entity]
        else -> null
    } ?: return null
    return when {
        code <= 0 || code > 0x10FFFF || code in 0xD800..0xDFFF -> "�"
        code < 0x10000 -> Char(code).toString()
        else -> {
            val v = code - 0x10000
            charArrayOf(Char(0xD800 + (v shr 10)), Char(0xDC00 + (v and 0x3FF))).concatToString()
        }
    }
}
