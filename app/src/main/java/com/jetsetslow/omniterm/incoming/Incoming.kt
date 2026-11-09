package com.jetsetslow.omniterm.incoming

import android.content.ClipData
import android.content.ContentResolver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import androidx.annotation.StringRes
import androidx.core.content.IntentCompat
import com.jetsetslow.omniterm.MainActivity
import com.jetsetslow.omniterm.R
import com.jetsetslow.omniterm.data.SshLink

/**
 * What another app hands OmniTerm: an `ssh://` link, shared text, or shared files. Nothing here
 * connects, saves or uploads; each opens a screen where the user decides.
 *
 * [IncomingActivity] reads it and passes it on to [MainActivity] in OmniTerm's own task, and
 * [MainActivity] reads it again with the same rules, because any app can start it directly.
 */
sealed interface Incoming {
    data class Link(val link: SshLink) : Incoming
    data class Text(val text: String) : Incoming
    /** Files OmniTerm may read, and how many others it refused. */
    data class Files(val uris: List<Uri>, val refused: Int = 0) : Incoming
    /** Something was handed over that OmniTerm will not use, and why. */
    data class Unusable(@StringRes val reason: Int) : Incoming

    companion object {
        /** Longer text is not a script anyone typed. */
        const val TEXT_LIMIT = 65_536

        /** What [intent] hands over, or null when it hands over nothing. */
        fun read(context: Context, intent: Intent): Incoming? = when (intent.action) {
            Intent.ACTION_VIEW -> intent.data?.takeIf { it.scheme.equals(SshLink.SCHEME, ignoreCase = true) }?.let { uri ->
                SshLink.parse(uri.toString())?.let(::Link) ?: Unusable(R.string.incoming_bad_link)
            }
            Intent.ACTION_SEND, Intent.ACTION_SEND_MULTIPLE -> {
                val offered = sharedUris(intent)
                val usable = offered.filter { readable(context, it) }
                val text = intent.getCharSequenceExtra(Intent.EXTRA_TEXT)?.toString()?.trim().orEmpty()
                when {
                    usable.isNotEmpty() -> Files(usable, refused = offered.size - usable.size)
                    offered.isNotEmpty() -> Unusable(R.string.incoming_files_refused)
                    text.length > TEXT_LIMIT -> Unusable(R.string.incoming_text_too_long)
                    text.isNotEmpty() -> SshLink.parse(text)?.let(::Link) ?: Text(text)
                    else -> null
                }
            }
            else -> null
        }

        /**
         * [incoming] as an intent for [MainActivity] in OmniTerm's own task, so a share from another
         * app opens the app the user already has rather than a second copy inside the sender's task.
         * Shared files keep their read grant: it moves to [MainActivity], which lives as long as the
         * upload can take, where the forwarding activity's grant ends when it finishes.
         */
        fun forward(context: Context, incoming: Incoming): Intent? {
            val intent = Intent(context, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
            return when (incoming) {
                is Link -> intent.setAction(Intent.ACTION_VIEW).setData(Uri.parse(incoming.link.uri))
                is Text -> intent.setAction(Intent.ACTION_SEND).setType("text/plain").putExtra(Intent.EXTRA_TEXT, incoming.text)
                is Files -> {
                    // ClipData only, which is what carries the grant; the URIs once, not twice.
                    val clip = ClipData.newRawUri(null, incoming.uris.first())
                    incoming.uris.drop(1).forEach { clip.addItem(ClipData.Item(it)) }
                    intent.setAction(Intent.ACTION_SEND_MULTIPLE).setType("*/*").addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION).also { it.clipData = clip }
                }
                is Unusable -> null
            }
        }

        /** Clears what [read] took from [intent], so a rotation does not hand it over again. */
        fun consume(intent: Intent) {
            if (intent.data?.scheme.equals(SshLink.SCHEME, ignoreCase = true)) intent.data = null
            intent.removeExtra(Intent.EXTRA_TEXT)
            intent.removeExtra(Intent.EXTRA_STREAM)
            intent.clipData = null
            if (intent.action in setOf(Intent.ACTION_VIEW, Intent.ACTION_SEND, Intent.ACTION_SEND_MULTIPLE)) {
                intent.action = Intent.ACTION_MAIN
            }
        }

        private fun sharedUris(intent: Intent): List<Uri> = buildList {
            if (intent.action == Intent.ACTION_SEND) {
                IntentCompat.getParcelableExtra(intent, Intent.EXTRA_STREAM, Uri::class.java)?.let(::add)
            } else {
                IntentCompat.getParcelableArrayListExtra(intent, Intent.EXTRA_STREAM, Uri::class.java)?.let(::addAll)
            }
            intent.clipData?.let { clip -> for (i in 0 until clip.itemCount) clip.getItemAt(i).uri?.let(::add) }
        }.distinct()

        /**
         * Only another app's content: never a `file://` path, which would have OmniTerm read its own
         * private files, and never OmniTerm's own providers. Refuses everything if OmniTerm cannot
         * list its own providers.
         */
        private fun readable(context: Context, uri: Uri): Boolean {
            if (uri.scheme != ContentResolver.SCHEME_CONTENT) return false
            val authority = uri.authority?.takeIf { it.isNotEmpty() } ?: return false
            val own = ownAuthorities(context) ?: return false
            return authority !in own
        }

        private fun ownAuthorities(context: Context): Set<String>? = runCatching {
            val pm = context.packageManager
            val info = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                pm.getPackageInfo(context.packageName, PackageManager.PackageInfoFlags.of(PackageManager.GET_PROVIDERS.toLong()))
            } else {
                @Suppress("DEPRECATION")
                pm.getPackageInfo(context.packageName, PackageManager.GET_PROVIDERS)
            }
            info.providers.orEmpty().flatMap { it.authority.orEmpty().split(';') }.filter { it.isNotEmpty() }.toSet()
        }.getOrNull()
    }
}
