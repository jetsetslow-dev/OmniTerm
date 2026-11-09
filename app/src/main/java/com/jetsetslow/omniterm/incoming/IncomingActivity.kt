package com.jetsetslow.omniterm.incoming

import android.app.Activity
import android.os.Bundle
import android.widget.Toast
import com.jetsetslow.omniterm.R

/**
 * Receives `ssh://` links and shares from other apps, and passes what it can use to MainActivity in
 * OmniTerm's own task. It shows nothing and finishes at once: started inside the sender's task, a
 * full OmniTerm there would be a second copy of the app beside the one the user already has.
 */
class IncomingActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val app = applicationContext
        when (val incoming = Incoming.read(this, intent)) {
            null -> Unit
            is Incoming.Unusable -> Toast.makeText(app, incoming.reason, Toast.LENGTH_LONG).show()
            else -> Incoming.forward(this, incoming)?.let { forward ->
                if (incoming is Incoming.Files && incoming.refused > 0) {
                    Toast.makeText(app, resources.getQuantityString(R.plurals.incoming_some_files_refused, incoming.refused, incoming.refused), Toast.LENGTH_LONG).show()
                }
                // A sender can withdraw its grant before this runs; say so rather than fail later.
                runCatching { startActivity(forward) }.onFailure {
                    Toast.makeText(app, R.string.incoming_files_refused, Toast.LENGTH_LONG).show()
                }
            }
        }
        finish()
    }
}
