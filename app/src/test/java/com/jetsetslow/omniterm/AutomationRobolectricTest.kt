package com.jetsetslow.omniterm

import android.content.ComponentName
import android.content.Intent
import com.jetsetslow.omniterm.automation.AutomationReplies
import com.jetsetslow.omniterm.automation.AutomationRequest
import com.jetsetslow.omniterm.data.Automation
import com.jetsetslow.omniterm.data.QuickScriptEntity
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/** Automation's tokens, its result, and the Tasker/Locale protocol pieces it sends and reads. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class AutomationRobolectricTest {

    @Test
    fun tokensAreRandomUrlSafeAndOnlyTheirHashIsKept() {
        val a = Automation.newToken()
        val b = Automation.newToken()
        assertNotEquals(a, b)
        assertTrue(a, Automation.looksLikeToken(a))
        assertTrue(a, a.startsWith("omt_") && a.length == 26)
        assertTrue(a, a.drop(4).all { it.isLetterOrDigit() || it == '-' || it == '_' })
        // SHA-256 of "abc", the standard test vector.
        assertEquals("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", Automation.hash("abc"))
        assertEquals(64, Automation.hash(a).length)
    }

    @Test
    fun onlyATokensShapeIsLookedUp() {
        listOf(null, "", "omt_", "omt_short", "xyz_" + "a".repeat(22), "omt_" + "a".repeat(21) + "=", "omt_" + "é".repeat(22), "omt_" + "a".repeat(23))
            .forEach { assertFalse("$it", Automation.looksLikeToken(it)) }
        assertTrue(Automation.looksLikeToken("omt_" + "aZ09-_".repeat(4).take(22)))
    }

    @Test
    fun hostIdsRoundTripSortedWithoutRepeatsOrJunk() {
        assertEquals("2,5,9", Automation.joinServerIds(listOf(9, 2, 5, 2)))
        assertEquals(listOf(2, 5, 9), Automation.parseServerIds("2, 5,9,,x,-1,0,5"))
        assertEquals(emptyList<Int>(), Automation.parseServerIds(""))
    }

    @Test
    fun aHostIsSkippedOnlyWhenTheScriptNamesAnotherOs() {
        fun script(os: String) = QuickScriptEntity(emoji = "", name = "s", command = "true", color = "cyan", targetOs = os)
        assertFalse(Automation.skipsOs(script("Any"), "Windows"))
        assertFalse(Automation.skipsOs(script(""), "Linux"))
        assertFalse(Automation.skipsOs(script("Linux"), "linux"))
        assertTrue(Automation.skipsOs(script("Windows"), "Linux"))
        assertTrue(Automation.skipsOs(script("Darwin"), "FreeBSD"))
    }

    @Test
    fun aRunSucceedsOnlyWhenItRanAndEveryHostThatRanSucceeded() {
        val ok = Automation.HostResult(1, "nas", 0, "fine\n")
        val skipped = Automation.HostResult(2, "win", null, "", "Skipped, not Linux: win")
        val failed = Automation.HostResult(3, "pi", 3, "boom\n", "Exited with status 3.")

        Automation.RunResult(listOf(ok, skipped)).let {
            assertTrue(it.succeeded)
            assertEquals(0, it.exit)
            assertNull(it.errorMessage)
        }
        Automation.RunResult(listOf(ok, failed)).let {
            assertFalse(it.succeeded)
            assertEquals(3, it.exit)
            assertEquals("pi: Exited with status 3.", it.errorMessage)
            assertEquals(listOf("pi"), it.failed.map { h -> h.name })
        }
        Automation.RunResult(listOf(skipped)).let {
            assertFalse("nothing ran", it.succeeded)
            assertEquals(1, it.exit)
            assertEquals("win: Skipped, not Linux: win", it.errorMessage)
        }
        Automation.RunResult(emptyList(), "Automation is off").let {
            assertFalse(it.succeeded)
            assertEquals("Automation is off", it.errorMessage)
        }
    }

    @Test
    fun outputIsEachHostsUnderItsNameAndKeepsItsEnd() {
        assertEquals("fine", Automation.RunResult(listOf(Automation.HostResult(1, "nas", 0, "fine\n"))).combinedOutput())
        val two = Automation.RunResult(
            listOf(Automation.HostResult(1, "nas", 0, "fine\n"), Automation.HostResult(3, "pi", 255, "", "Auth fail")),
        )
        assertEquals("== nas ==\nfine\n\n== pi ==\nAuth fail", two.combinedOutput())
        val long = "x".repeat(Automation.REPLY_OUTPUT_CHARS) + "END"
        val kept = Automation.RunResult(listOf(Automation.HostResult(1, "nas", 0, long))).combinedOutput()
        assertEquals(Automation.REPLY_OUTPUT_CHARS, kept.length)
        assertTrue(kept.endsWith("END"))
    }

    @Test
    fun taskerGetsItsVariablesWithErrmsgOnlyOnFailure() {
        val ok = Automation.Plugin.variables(Automation.RunResult(listOf(Automation.HostResult(1, "nas", 0, "fine"))))
        assertEquals("fine", ok.getString("%output"))
        assertEquals("0", ok.getString("%exit"))
        assertEquals("", ok.getString("%failed_hosts"))
        assertFalse(ok.containsKey("%errmsg"))

        val bad = Automation.Plugin.variables(
            Automation.RunResult(listOf(Automation.HostResult(1, "nas", 0, ""), Automation.HostResult(3, "pi", 2, "", "Exited with status 2."))),
        )
        assertEquals("2", bad.getString("%exit"))
        assertEquals("pi", bad.getString("%failed_hosts"))
        assertEquals("pi: Exited with status 2.", bad.getString("%errmsg"))
    }

    @Test
    fun thePluginBundleCarriesOnlyOurTokenInPlatformTypes() {
        val token = Automation.newToken()
        val bundle = Automation.Plugin.bundleFor(token)
        assertEquals(token, Automation.Plugin.tokenFrom(bundle))
        assertEquals(setOf(Automation.Plugin.BUNDLE_TOKEN, Automation.Plugin.BUNDLE_VERSION), bundle.keySet())
        assertNull(Automation.Plugin.tokenFrom(null))
        assertNull(Automation.Plugin.tokenFrom(android.os.Bundle().apply { putString(Automation.Plugin.BUNDLE_TOKEN, "not a token") }))
    }

    @Test
    fun theCompletionIntentMustNameAnAppAndLosesWhatItCouldGrant() {
        val implicit = Intent("net.dinglisch.android.tasker.ACTION_PLUGIN_COMPLETE").toUri(Intent.URI_INTENT_SCHEME)
        assertNull("anything listening could read the output", AutomationReplies.completionIntent(implicit))
        assertNull(AutomationReplies.completionIntent("not a uri at all"))

        val sent = Intent("done")
            .setComponent(ComponentName("net.dinglisch.android.taskerm", "net.dinglisch.android.taskerm.Receiver"))
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION or Intent.FLAG_RECEIVER_FOREGROUND)
            .apply { selector = Intent(Intent.ACTION_VIEW) }
            .toUri(Intent.URI_INTENT_SCHEME)
        val intent = AutomationReplies.completionIntent(sent)!!
        assertEquals("net.dinglisch.android.taskerm", intent.component?.packageName)
        assertEquals(0, intent.flags and (Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION))
        assertEquals("other flags stay", Intent.FLAG_RECEIVER_FOREGROUND, intent.flags and Intent.FLAG_RECEIVER_FOREGROUND)
        assertNull(intent.selector)
    }

    @Test
    fun thePlainReplyGoesOnlyToTheNamedPackage() {
        val result = Automation.RunResult(listOf(Automation.HostResult(1, "nas", 0, "fine")))
        assertNull(AutomationReplies.replyIntent(AutomationRequest(1, "h"), result))
        assertNull(AutomationReplies.replyIntent(AutomationRequest(1, "h", replyPackage = "com.example"), result))
        val reply = AutomationReplies.replyIntent(
            AutomationRequest(1, "h", replyPackage = "com.example", replyAction = "com.example.DONE", requestId = "r1"),
            result,
        )!!
        assertEquals("com.example", reply.`package`)
        assertEquals("com.example.DONE", reply.action)
        assertEquals(0, reply.getIntExtra(Automation.EXTRA_EXIT, -9))
        assertEquals("fine", reply.getStringExtra(Automation.EXTRA_OUTPUT))
        assertEquals("r1", reply.getStringExtra(Automation.EXTRA_REQUEST_ID))
        assertFalse(reply.hasExtra(Automation.EXTRA_ERROR))
    }

    @Test
    fun aRequestSurvivesTheJobsExtrasWithoutItsToken() {
        val request = AutomationRequest(7, "abc123", completionIntent = "intent:#Intent;end", replyPackage = "p", replyAction = "a", requestId = "r")
        val extras = request.toExtras()
        assertEquals(request, AutomationRequest.from(extras))
        assertFalse("only the hash travels", extras.keySet().any { extras.getString(it)?.startsWith("omt_") == true })
        assertNull(AutomationRequest.from(android.os.PersistableBundle()))
    }
}
