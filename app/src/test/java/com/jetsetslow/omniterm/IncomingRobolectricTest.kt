package com.jetsetslow.omniterm

import android.app.Application
import android.content.ClipData
import android.content.Intent
import android.net.Uri
import androidx.test.core.app.ApplicationProvider
import com.jetsetslow.omniterm.data.SshLink
import com.jetsetslow.omniterm.incoming.Incoming
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/**
 * What OmniTerm takes from a link or a share, what it refuses, and how it passes it on to its main
 * screen without losing anything or the read grant.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class IncomingRobolectricTest {
    private val app: Application get() = ApplicationProvider.getApplicationContext()
    private val other = Uri.parse("content://com.example.gallery.files/photo/1")
    private val other2 = Uri.parse("content://com.example.gallery.files/photo/2")

    @Test fun aLinkIsReadOrRefused() {
        assertEquals(Incoming.Link(SshLink("nas.lan", 2222, "admin")), read(view("ssh://admin:pw@nas.lan:2222/")))
        assertEquals(Incoming.Unusable(R.string.incoming_bad_link), read(view("ssh://-oProxyCommand=x")))
        assertNull("not OmniTerm's to open", read(view("https://nas.lan")))
        assertNull(read(Intent(Intent.ACTION_VIEW)))
    }

    @Test fun sharedTextIsAScriptOrALink() {
        assertEquals(Incoming.Text("uptime"), read(text("  uptime \n")))
        assertEquals(Incoming.Link(SshLink("pi", 22, null)), read(text("ssh://pi")))
        assertEquals(Incoming.Unusable(R.string.incoming_text_too_long), read(text("x".repeat(Incoming.TEXT_LIMIT + 1))))
        assertEquals(Incoming.Text("x".repeat(Incoming.TEXT_LIMIT)), read(text("x".repeat(Incoming.TEXT_LIMIT))))
        assertNull(read(text("   ")))
    }

    @Test fun sharedFilesAreReadFromTheExtraAndTheClip() {
        val one = Intent(Intent.ACTION_SEND).putExtra(Intent.EXTRA_STREAM, other)
        assertEquals(Incoming.Files(listOf(other)), read(one))
        val many = Intent(Intent.ACTION_SEND_MULTIPLE).putParcelableArrayListExtra(Intent.EXTRA_STREAM, arrayListOf(other))
        many.clipData = ClipData.newRawUri(null, other).apply { addItem(ClipData.Item(other2)) }
        assertEquals("each once", Incoming.Files(listOf(other, other2)), read(many))
        // A file wins over text the sender added, such as a caption.
        assertEquals(Incoming.Files(listOf(other)), read(Intent(one).putExtra(Intent.EXTRA_TEXT, "caption")))
    }

    @Test fun pathsAndOmniTermsOwnFilesAreRefused() {
        val path = Uri.parse("file:///data/data/${app.packageName}/databases/app.db")
        // Android opens a file: URI by its path whatever its host, so a host does not make it content.
        val pathWithHost = Uri.parse("file://localhost/data/data/${app.packageName}/databases/app.db")
        val own = Uri.parse("content://${app.packageName}.fileprovider/cache/crash.txt")
        val noAuthority = Uri.parse("content:///x")
        for (uri in listOf(path, pathWithHost, own, noAuthority)) {
            assertEquals(uri.toString(), Incoming.Unusable(R.string.incoming_files_refused), read(Intent(Intent.ACTION_SEND).putExtra(Intent.EXTRA_STREAM, uri)))
        }
        val mixed = Intent(Intent.ACTION_SEND_MULTIPLE).putParcelableArrayListExtra(Intent.EXTRA_STREAM, arrayListOf(own, other, path))
        assertEquals("the others are kept and the refused counted", Incoming.Files(listOf(other), refused = 2), read(mixed))
    }

    @Test fun whatIsPassedOnReadsBackTheSameAndKeepsTheGrant() {
        val link = Incoming.Link(SshLink("h", 2222, "jo doe@corp"))
        val files = Incoming.Files(listOf(other, other2))
        for (incoming in listOf(link, Incoming.Text("df -h"), files)) {
            val forward = Incoming.forward(app, incoming)!!
            assertEquals(MainActivity::class.java.name, forward.component?.className)
            assertTrue("OmniTerm's own task", forward.flags and Intent.FLAG_ACTIVITY_NEW_TASK != 0)
            assertTrue(forward.flags and Intent.FLAG_ACTIVITY_SINGLE_TOP != 0)
            assertEquals(incoming, read(forward))
        }
        val forward = Incoming.forward(app, files)!!
        assertTrue("the read grant goes with the files", forward.flags and Intent.FLAG_GRANT_READ_URI_PERMISSION != 0)
        assertEquals(2, forward.clipData?.itemCount)
        assertFalse("never write", forward.flags and Intent.FLAG_GRANT_WRITE_URI_PERMISSION != 0)
        assertNull(Incoming.forward(app, Incoming.Unusable(R.string.incoming_bad_link)))
        assertEquals(0, Incoming.forward(app, link)!!.flags and Intent.FLAG_GRANT_READ_URI_PERMISSION)
    }

    @Test fun whatWasReadIsConsumed() {
        val shared = Intent(Intent.ACTION_SEND).putExtra(Intent.EXTRA_STREAM, other).putExtra(Intent.EXTRA_TEXT, "t")
        shared.clipData = ClipData.newRawUri(null, other)
        Incoming.consume(shared)
        assertEquals(Intent.ACTION_MAIN, shared.action)
        assertNull(shared.clipData)
        assertNull(read(shared))
        val link = view("ssh://h")
        Incoming.consume(link)
        assertNull(link.data)
        val other = Intent("com.example.OTHER").setData(Uri.parse("https://x"))
        Incoming.consume(other)
        assertEquals("com.example.OTHER", other.action)
        assertEquals("https://x", other.dataString)
    }

    private fun read(intent: Intent) = Incoming.read(app, intent)
    private fun view(uri: String) = Intent(Intent.ACTION_VIEW, Uri.parse(uri))
    private fun text(s: String) = Intent(Intent.ACTION_SEND).setType("text/plain").putExtra(Intent.EXTRA_TEXT, s)
}
