package com.jetsetslow.omniterm

import com.jetsetslow.omniterm.data.ConflictAction
import com.jetsetslow.omniterm.data.ConflictVerdict
import com.jetsetslow.omniterm.data.RemoteCommands
import com.jetsetslow.omniterm.data.RemoteParsers
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Copy/move conflicts must be decided by CONTENT, and unverifiable cases must stay unverifiable.
 *
 * Matching name, size and timestamp is not proof two files are the same — a copy tool reproduces
 * mtime exactly, and different content routinely shares a size. So the only thing allowed to yield
 * IDENTICAL is a digest match, and anything we could not check must surface as UNKNOWN so the UI can
 * say "not verified" rather than implying a comparison happened.
 */
class TransferConflictTest {

    @Test
    fun digestMatchIsTheOnlyThingThatYieldsIdentical() {
        val out = "notes.txt\tIDENTICAL\t120\t120\t1700000000\t1700000000"
        val c = RemoteParsers.parseTransferConflicts(out).single()
        assertEquals(ConflictVerdict.IDENTICAL, c.verdict)
        // Proven-identical overwrites destroy nothing, so this is the one safe default.
        assertEquals(ConflictAction.OVERWRITE, c.action)
    }

    @Test
    fun sameSizeAndMtimeWithoutADigestIsNeverReportedIdentical() {
        // Identical size AND identical mtime, but the host could not hash — must NOT claim a match.
        val out = "data.bin\tUNKNOWN\t4096\t4096\t1700000000\t1700000000"
        val c = RemoteParsers.parseTransferConflicts(out).single()
        assertEquals(ConflictVerdict.UNKNOWN, c.verdict)
        assertFalse("Unverified pair must not be treated as identical", c.verdict == ConflictVerdict.IDENTICAL)
        // Safe default: preserve both rather than silently destroying one.
        assertEquals(ConflictAction.KEEP_BOTH, c.action)
    }

    @Test
    fun differingContentDefaultsToKeepBothNotOverwrite() {
        val out = "report.pdf\tDIFFERENT\t900\t1200\t1700000000\t1699999999"
        val c = RemoteParsers.parseTransferConflicts(out).single()
        assertEquals(ConflictVerdict.DIFFERENT, c.verdict)
        assertEquals(ConflictAction.KEEP_BOTH, c.action)
        assertEquals(900L, c.sourceSize)
        assertEquals(1200L, c.destSize)
    }

    @Test
    fun directoriesAreFlaggedAsMergingRatherThanReplacing() {
        val out = "src\tDIR\t0\t0\t0\t0"
        assertEquals(ConflictVerdict.DIRECTORY, RemoteParsers.parseTransferConflicts(out).single().verdict)
    }

    /** An unrecognised verdict must degrade to UNKNOWN, never be dropped or assumed benign. */
    @Test
    fun unrecognisedVerdictBecomesUnknownInsteadOfBeingDiscarded() {
        val out = "weird.txt\tSOMETHING_NEW\t10\t10\t1\t1"
        val c = RemoteParsers.parseTransferConflicts(out).single()
        assertEquals(ConflictVerdict.UNKNOWN, c.verdict)
    }

    @Test
    fun malformedLinesAreIgnoredWithoutLosingValidOnes() {
        val out = listOf(
            "",
            "no-tabs-here",
            "short\tDIFFERENT\t1",
            "good.txt\tDIFFERENT\t5\t7\t100\t200",
        ).joinToString("\n")
        val all = RemoteParsers.parseTransferConflicts(out)
        assertEquals(1, all.size)
        assertEquals("good.txt", all.single().name)
    }

    /** The probe must fall back across hash tools and never claim a match when none is available. */
    @Test
    fun compareCommandTriesSeveralDigestToolsAndHandlesTheirAbsence() {
        val cmd = RemoteCommands.compareForConflicts("/tmp/dest", listOf("/src/a.txt"))
        listOf("sha256sum", "shasum", "md5sum", "cksum").forEach {
            assertTrue("missing digest fallback $it", cmd.contains(it))
        }
        assertTrue("must emit UNKNOWN when no hash tool exists", cmd.contains("UNKNOWN"))
        // Size is compared first so a cheap decisive answer skips hashing entirely.
        assertTrue(cmd.contains("DIFFERENT"))
    }

    @Test
    fun skippedNamesAreNeverCopiedAndKeepBothWritesASuffixedName() {
        val script = RemoteCommands.pasteResolved(
            destDir = "/dest",
            sources = listOf("/src/keep.txt", "/src/skip.txt", "/src/both.txt"),
            isMove = false,
            skip = setOf("skip.txt"),
            keepBoth = setOf("both.txt"),
        )
        assertTrue("plain overwrite missing", script.contains("'/src/keep.txt'"))
        assertFalse("skipped file must not be copied", script.contains("'/src/skip.txt'"))
        assertTrue("keep-both must probe for a free name", script.contains("both"))
        assertTrue("keep-both must build a numbered variant", script.contains("(\$OT_I)"))
    }

    @Test
    fun skippingEveryItemProducesANoOpRatherThanAnEmptyCommand() {
        val script = RemoteCommands.pasteResolved(
            destDir = "/dest",
            sources = listOf("/src/a.txt"),
            isMove = true,
            skip = setOf("a.txt"),
            keepBoth = emptySet(),
        )
        assertEquals("true", script)
    }

    @Test
    fun moveUsesMvAndCopyUsesCp() {
        val mv = RemoteCommands.pasteResolved("/d", listOf("/s/f"), true, emptySet(), emptySet())
        val cp = RemoteCommands.pasteResolved("/d", listOf("/s/f"), false, emptySet(), emptySet())
        assertTrue(mv.startsWith("mv -f --"))
        assertTrue(cp.startsWith("cp -a --"))
    }
}
