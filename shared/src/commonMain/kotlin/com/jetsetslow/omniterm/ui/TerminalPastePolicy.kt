package com.jetsetslow.omniterm.ui

/**
 * An IME commit larger than this many inserted code points is treated as a paste and routed to the
 * confirmation dialog instead of being typed straight into the remote.
 */
const val LARGE_PASTE_CODE_POINTS: Int = 100

/**
 * Wraps a paste in bracketed-paste markers when the remote asked for them (DECSET 2004).
 *
 * readline treats EVERYTHING between the markers as literal text — including a trailing Enter — so
 * a pasted command ending in a newline was echoed at the prompt but never executed (and the IME's
 * multi-line commit path funnels through the same paste). Matching mainstream terminals, the pasted
 * body is wrapped but any trailing CRs are sent AFTER the closing marker so they act as real Enter
 * presses. Interior newlines stay inside the bracket (literal, as the mode intends). [normalized]
 * must already use CR line endings.
 */
fun bracketedPastePayload(normalized: String, bracketed: Boolean): String {
    if (!bracketed) return normalized
    val body = normalized.trimEnd('\r')
    val trailingEnters = normalized.substring(body.length)
    return "\u001B[200~$body\u001B[201~$trailingEnters"
}

/** True only for one IME Enter commit; multi-line clipboard/paste blocks stay byte-preserving. */
fun isSingleTerminalEnter(text: String): Boolean =
    text == "\n" || text == "\r" || text == "\r\n"

/**
 * UTF-16 index up to which [first] and [second] share the same Unicode scalar values. Comparing
 * code points rather than chars keeps a surrogate pair (emoji, CJK extension) from being split into
 * half a character.
 */
fun commonCodePointPrefixIndex(first: String, second: String): Int {
    var index = 0
    while (index < first.length && index < second.length) {
        val width = codePointWidthAt(first, index)
        if (width != codePointWidthAt(second, index)) break
        if (first.regionMatches(index, second, index, width)) index += width else break
    }
    return index
}

/**
 * Number of Unicode scalar values [new] shares with [old] at the start and end combined (clamped so
 * the two matched regions never overlap). Subtracting this from [new]'s code-point count gives the
 * changed middle size used to distinguish a paste from an incremental swipe edit.
 */
private fun longestCommonAffix(old: String, new: String): Int {
    val oldPoints = old.toCodePoints()
    val newPoints = new.toCodePoints()
    val max = minOf(oldPoints.size, newPoints.size)
    var prefix = 0
    while (prefix < max && oldPoints[prefix] == newPoints[prefix]) prefix++
    var suffix = 0
    while (suffix < max - prefix &&
        oldPoints[oldPoints.size - 1 - suffix] == newPoints[newPoints.size - 1 - suffix]
    ) {
        suffix++
    }
    return prefix + suffix
}

/** Code points [new] adds over [old], ignoring a shared prefix and suffix. */
fun insertedCodePointDelta(old: String, new: String): Int =
    (new.codePointCount() - longestCommonAffix(old, new)).coerceAtLeast(0)

/** True when an IME commit is big enough to be a paste rather than typing. */
fun isLargePaste(old: String, new: String): Boolean =
    insertedCodePointDelta(old, new) > LARGE_PASTE_CODE_POINTS

private fun codePointWidthAt(value: String, index: Int): Int =
    if (index + 1 < value.length && value[index].isHighSurrogate() && value[index + 1].isLowSurrogate()) 2 else 1

private fun String.codePointCount(): Int {
    var count = 0
    var index = 0
    while (index < length) {
        index += codePointWidthAt(this, index)
        count++
    }
    return count
}

private fun String.toCodePoints(): IntArray {
    val points = IntArray(codePointCount())
    var index = 0
    var slot = 0
    while (index < length) {
        val width = codePointWidthAt(this, index)
        points[slot++] = if (width == 2) {
            0x10000 + ((this[index].code - 0xD800) shl 10) + (this[index + 1].code - 0xDC00)
        } else {
            this[index].code
        }
        index += width
    }
    return points
}
