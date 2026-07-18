package com.jetsetslow.omniterm

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.widget.Button
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import androidx.appcompat.app.AppCompatActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.Surface
import androidx.compose.ui.Modifier
import com.jetsetslow.omniterm.ui.AppViewModel
import com.jetsetslow.omniterm.ui.MainAppScreen
import com.jetsetslow.omniterm.ui.flavorRequestInAppReview
import com.jetsetslow.omniterm.ui.theme.MyApplicationTheme
import java.util.concurrent.atomic.AtomicBoolean

class MainActivity : AppCompatActivity() {
  private var appViewModel: AppViewModel? = null
  companion object {
    const val EXTRA_E2E_FORCE_STARTUP_CRASH = "com.jetsetslow.omniterm.extra.E2E_FORCE_STARTUP_CRASH"
    const val crashPrefsName = "startup_crash_report"
    const val crashKey = "last_crash"
    const val crashTimeKey = "last_crash_time"
    const val crashTtlMs = 7 * 24 * 60 * 60 * 1000L
    val crashRecorderInstalled = AtomicBoolean(false)

    fun crashEnvironment(): String =
      "App version: ${BuildConfig.VERSION_NAME} (${BuildConfig.VERSION_CODE}), ${BuildConfig.DISTRIBUTION_NAME}\n" +
        "Device: ${android.os.Build.MANUFACTURER} ${android.os.Build.MODEL}, Android ${android.os.Build.VERSION.RELEASE} (API ${android.os.Build.VERSION.SDK_INT})"
  }
  // Where "Report on GitHub" sends users — a prefilled new-issue form they can review before
  // submitting (nothing is sent automatically; they choose what to share).
  private val issuesUrl = "https://github.com/jetsetslow-dev/OmniTerm/issues/new"

  override fun dispatchKeyEvent(event: android.view.KeyEvent): Boolean {
    val vm = appViewModel
    if (vm != null && event.action == android.view.KeyEvent.ACTION_DOWN &&
        vm.currentScreen == com.jetsetslow.omniterm.ui.Screen.Shell && vm.isTerminalConnected) {
      when (event.keyCode) {
        android.view.KeyEvent.KEYCODE_VOLUME_UP -> { vm.adjustTerminalFontSize(1); return true }
        android.view.KeyEvent.KEYCODE_VOLUME_DOWN -> { vm.adjustTerminalFontSize(-1); return true }
      }
    }
    return super.dispatchKeyEvent(event)
  }

  override fun onCreate(savedInstanceState: Bundle?) {
    super.onCreate(savedInstanceState)
    installCrashRecorder()

    val prefs = getSharedPreferences(crashPrefsName, Context.MODE_PRIVATE)
    val previousCrash = prefs.getString(crashKey, null)
    val crashAge = System.currentTimeMillis() - prefs.getLong(crashTimeKey, 0L)
    if (!previousCrash.isNullOrBlank() && crashAge < crashTtlMs) {
      showCrashReport(previousCrash)
      return
    } else if (!previousCrash.isNullOrBlank()) {
      // Stale report — clear it silently and proceed normally
      prefs.edit().remove(crashKey).remove(crashTimeKey).apply()
    }

    try {
      enableEdgeToEdge()
      if (BuildConfig.DEBUG && intent?.getBooleanExtra(EXTRA_E2E_FORCE_STARTUP_CRASH, false) == true) {
        // Opt-in instrumentation hook: exercises the real startup recovery UI without shipping a
        // crash button or killing the instrumentation process that must verify the result.
        throw IllegalStateException(
          "Controlled E2E startup crash: password=hunter2 Authorization: Bearer e2e-token host=192.0.2.123 /home/omnitermlab/private",
        )
      }
      // Acquire ViewModel before setContent so handleIntent can set the correct initial
      // screen (e.g. Shell from a notification tap) before the first frame is rendered.
      if (appViewModel == null) {
        appViewModel = androidx.lifecycle.ViewModelProvider(
          this,
          androidx.lifecycle.ViewModelProvider.AndroidViewModelFactory.getInstance(application)
        )[AppViewModel::class.java]
        handleIntent(intent)
      }
      showAppContent()
    } catch (t: Throwable) {
      val report = com.jetsetslow.omniterm.data.CrashLog.redactSensitive(
        "${crashEnvironment()}\nThread: main\n${formatCrash(t)}",
      )
      prefs.edit().putString(crashKey, report).putLong(crashTimeKey, System.currentTimeMillis()).apply()
      runCatching { com.jetsetslow.omniterm.data.CrashLog.record(this, report) }
      showCrashReport(report)
    }
  }

  override fun onNewIntent(intent: android.content.Intent) {
    super.onNewIntent(intent)
    setIntent(intent) // Keep getIntent() in sync for composables that observe it
    handleIntent(intent)
  }

  override fun onStart() {
    super.onStart()
    appViewModel?.relockIfNeeded()
  }

  override fun onStop() {
    super.onStop()
    appViewModel?.noteAppBackgrounded()
    // Clear focus from whatever text field is active before the activity stops. Backgrounding (e.g.
    // tapping a notification) tears down the IME text-input session; if a Compose text field is still
    // focused on resume it re-reports its position through the legacy cursor-anchor path against the
    // now-null session and crashes at draw time (LegacyCursorAnchorInfoController NPE). Dropping focus
    // app-wide here removes that stale session for ALL fields — terminal, editors, dialogs — at once.
    runCatching {
      currentFocus?.let { focused ->
        val imm = getSystemService(android.view.inputmethod.InputMethodManager::class.java)
        imm?.hideSoftInputFromWindow(focused.windowToken, 0)
        focused.clearFocus()
      }
    }
  }

  private var pendingSessionId: String? = null

  private fun handleIntent(intent: android.content.Intent?) {
    val sessionId = intent?.getStringExtra(SessionService.EXTRA_SESSION_ID)
    // Notification disconnect actions are handled by the non-exported SessionService. The exported
    // launcher Activity only honors resume/navigation intents.
    if (sessionId != null) {
      val vm = appViewModel
      if (vm != null) {
        vm.attachSession(sessionId)
      } else {
        pendingSessionId = sessionId
      }
    }
  }

  private fun showAppContent() {
    setContent {
      val viewModel: AppViewModel = androidx.lifecycle.viewmodel.compose.viewModel(
          factory = androidx.lifecycle.ViewModelProvider.AndroidViewModelFactory.getInstance(application)
      )
      appViewModel = viewModel

      // Intent is handled in onCreate (cold start) and onNewIntent (warm start).
      // Process any pendingSessionId that was set before the ViewModel was ready.
      androidx.compose.runtime.LaunchedEffect(Unit) {
          pendingSessionId?.let {
              viewModel.attachSession(it)
              pendingSessionId = null
          }
      }
      val keepOn = viewModel.isKeepScreenOnEnabled
      val window = this.window
      androidx.compose.runtime.LaunchedEffect(keepOn) {
        if (keepOn) {
            window.addFlags(android.view.WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        } else {
            window.clearFlags(android.view.WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
          }
      }
      // Play in-app review nudge (no-op on the openSource flavor). Play decides whether the
      // sheet actually shows, so consuming the flag immediately is safe.
      val reviewDue = viewModel.reviewPromptDue
      androidx.compose.runtime.LaunchedEffect(reviewDue) {
        if (reviewDue) {
          viewModel.onReviewPromptLaunched()
          flavorRequestInAppReview(this@MainActivity)
        }
      }
      // Blocks screenshots and hides terminal/credential content from the task switcher.
      val flagSecure = viewModel.isFlagSecureEnabled
      androidx.compose.runtime.LaunchedEffect(flagSecure) {
        if (flagSecure) {
            window.addFlags(android.view.WindowManager.LayoutParams.FLAG_SECURE)
        } else {
            window.clearFlags(android.view.WindowManager.LayoutParams.FLAG_SECURE)
        }
      }

      val isSysDark = androidx.compose.foundation.isSystemInDarkTheme()
      val isDark = viewModel.isDarkModeEnabled ?: isSysDark

      val textFontScale = when (viewModel.textScale) {
        "small" -> 0.8f
        "large" -> 1.1f
        else -> 0.92f
      }
      MyApplicationTheme(darkTheme = isDark, highContrast = viewModel.isAccessibilityEnabled, amoled = viewModel.isAmoledEnabled, fontScale = textFontScale) {
        Surface(modifier = Modifier.fillMaxSize()) {
          MainAppScreen(viewModel = viewModel)
        }
      }
    }
  }

  @android.annotation.SuppressLint("ApplySharedPref") // uncaught-exception state must be synchronous
  private fun installCrashRecorder() {
    if (!crashRecorderInstalled.compareAndSet(false, true)) return
    val appContext = applicationContext
    val previous = Thread.getDefaultUncaughtExceptionHandler()
    Thread.setDefaultUncaughtExceptionHandler { thread, throwable ->
      // Prepend version/build/device: release traces are obfuscated, and deobfuscating one needs
      // the mapping.txt from this exact build — so the version (= which mapping) must travel with
      // every report the user copies or shares.
      val report = com.jetsetslow.omniterm.data.CrashLog.redactSensitive(
        "${crashEnvironment()}\nThread: ${thread.name}\n${com.jetsetslow.omniterm.data.CrashLog.formatThrowable(throwable)}",
      )
      // The single key drives the on-launch crash screen; the history (About → Crash history) keeps
      // the last N so a non-startup crash like a draw NPE can still be reviewed and sent later.
      appContext.getSharedPreferences(crashPrefsName, Context.MODE_PRIVATE)
        .edit()
        .putString(crashKey, report)
        .putLong(crashTimeKey, System.currentTimeMillis())
        .commit()
      runCatching { com.jetsetslow.omniterm.data.CrashLog.record(appContext, report) }
      previous?.uncaughtException(thread, throwable)
    }
  }

  private fun formatCrash(t: Throwable): String = com.jetsetslow.omniterm.data.CrashLog.formatThrowable(t)

  /**
   * Open a prefilled GitHub "new issue" form for [report]. Nothing is submitted automatically — the
   * user lands on GitHub's editor and can review/redact before posting. GitHub's URL form can't
   * carry file attachments, so the body keeps a short headline + environment and points the user at
   * "Share full report" (and Copy report) for the complete trace, which avoids silently dropping the
   * most useful lines. Falls back to copying the URL if no browser can handle the intent.
   */
  private fun openGitHubIssue(report: String) {
    val headline = report.lineSequence().firstOrNull { it.isNotBlank() }?.take(160).orEmpty()
    val body = buildString {
      append("**Describe what you were doing when this happened:**\n\n\n")
      append("---\n")
      append(crashEnvironment()).append("\n\n")
      append("Crash:\n```\n").append(headline).append("\n```\n\n")
      append("_Attach the full report: tap \"Share full report\" on the crash screen (or paste from \"Copy report\")._\n")
    }
    val uri = Uri.parse(issuesUrl).buildUpon()
      .appendQueryParameter("title", "Crash: ${headline.take(120)}")
      .appendQueryParameter("body", body)
      .build()
    val intent = Intent(Intent.ACTION_VIEW, uri)
    if (intent.resolveActivity(packageManager) != null) {
      startActivity(intent)
    } else {
      // No browser available — hand the user the link so they can still file it elsewhere.
      val clipboard = getSystemService(android.content.ClipboardManager::class.java)
      clipboard.setPrimaryClip(android.content.ClipData.newPlainText("OmniTerm issue link", uri.toString()))
      android.widget.Toast.makeText(this, "No browser found — issue link copied to clipboard.", android.widget.Toast.LENGTH_LONG).show()
    }
  }

  /**
   * Write the full [report] (plus environment) to a private cache file and open the Android share
   * sheet with it attached, so the complete trace can go to a GitHub issue, email, or Drive without
   * truncation. The user picks the destination — nothing is sent automatically. Exposed only through
   * the app's own FileProvider (see file_paths.xml).
   */
  private fun shareFullReport(report: String) {
    // The full report (env header + thread + stack trace). `report` already begins with
    // crashEnvironment() (see installCrashRecorder), so don't prepend it again.
    val full = "OmniTerm crash report\n\n$report"
    try {
      val dir = java.io.File(cacheDir, "crash-reports").apply { mkdirs() }
      val file = java.io.File(dir, "omniterm-crash-report.txt")
      file.writeText(full)
      val uri = androidx.core.content.FileProvider.getUriForFile(this, "${packageName}.fileprovider", file)
      val send = Intent(Intent.ACTION_SEND).apply {
        type = "text/plain"
        putExtra(Intent.EXTRA_STREAM, uri)
        putExtra(Intent.EXTRA_SUBJECT, "OmniTerm crash report")
        // Put the FULL report in EXTRA_TEXT, not just the env header: many targets (Gmail,
        // messaging, notes) show/keep EXTRA_TEXT and ignore the attached file, so a 2-line env was
        // all that survived. The file attachment stays for targets that prefer attachments.
        putExtra(Intent.EXTRA_TEXT, full)
        addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
      }
      startActivity(Intent.createChooser(send, "Share crash report"))
    } catch (e: Exception) {
      // Even if the file/provider failed, still let the user share the text itself.
      runCatching {
        val send = Intent(Intent.ACTION_SEND).apply {
          type = "text/plain"
          putExtra(Intent.EXTRA_SUBJECT, "OmniTerm crash report")
          putExtra(Intent.EXTRA_TEXT, full)
        }
        startActivity(Intent.createChooser(send, "Share crash report"))
      }.onFailure {
        android.widget.Toast.makeText(this, "Couldn't share the report: ${e.message}", android.widget.Toast.LENGTH_LONG).show()
      }
    }
  }

  private fun showCrashReport(report: String) {
    val content = LinearLayout(this).apply {
      orientation = LinearLayout.VERTICAL
      setPadding(32, 32, 32, 32)
    }
    content.addView(TextView(this).apply {
      text = getString(R.string.crash_start_title)
      textSize = 20f
      setTypeface(typeface, android.graphics.Typeface.BOLD)
    })
    content.addView(TextView(this).apply {
      text = if (BuildConfig.DEBUG)
        "The crash report below was saved on this device. Clear it, then try opening the app again."
      else
        "A crash report was saved on this device. Clear it and try opening the app again. " +
          "To help fix this, tap Report on GitHub to open a prefilled issue (you can review and " +
          "edit it before posting), then Share full report to attach the complete log — or Copy " +
          "report to paste it yourself. Nothing is sent automatically."
      textSize = 14f
      setPadding(0, 16, 0, 16)
    })
    // Stack actions vertically so four buttons never overflow on a narrow screen.
    val buttonRow = LinearLayout(this).apply {
      orientation = LinearLayout.VERTICAL
      setPadding(0, 0, 0, 0)
    }
    buttonRow.addView(Button(this).apply {
      text = getString(R.string.crash_clear_retry)
      setOnClickListener {
        getSharedPreferences(crashPrefsName, Context.MODE_PRIVATE)
          .edit().remove(crashKey).remove(crashTimeKey).apply()
        intent?.removeExtra(EXTRA_E2E_FORCE_STARTUP_CRASH)
        recreate()
      }
    })
    buttonRow.addView(Button(this).apply {
      text = getString(R.string.crash_report_github)
      setOnClickListener { openGitHubIssue(report) }
    })
    buttonRow.addView(Button(this).apply {
      text = getString(R.string.crash_share_full)
      setOnClickListener { shareFullReport(report) }
    })
    buttonRow.addView(Button(this).apply {
      text = getString(R.string.crash_copy)
      setOnClickListener {
        val clipboard = getSystemService(android.content.ClipboardManager::class.java)
        clipboard.setPrimaryClip(android.content.ClipData.newPlainText("OmniTerm crash report", report))
        // Android 13+ shows its own copy confirmation; on older versions this is the only feedback.
        android.widget.Toast.makeText(this@MainActivity, "Crash report copied to clipboard.", android.widget.Toast.LENGTH_SHORT).show()
      }
    })
    content.addView(buttonRow)
    // Release builds show only the headline (exception type + message); the raw stack trace —
    // class names, line numbers, device paths — stays out of the UI but remains in the clipboard
    // export above so users can still send actionable reports.
    val visibleReport = if (BuildConfig.DEBUG) {
      report
    } else {
      // Keep the env + "Thread: …" prefix and the exception line(s); cut at the first stack frame.
      // (6 lines covers: 2 environment lines, the Thread line, and the exception/"Caused by" lines.)
      val headline = report.lines().takeWhile { !it.trimStart().startsWith("at ") }.take(6)
      val hiddenLines = (report.lines().size - headline.size).coerceAtLeast(0)
      headline.joinToString("\n") +
        "\n\n($hiddenLines more lines hidden — tap Copy report for the full trace)"
    }
    content.addView(TextView(this).apply {
      text = visibleReport
      textSize = 12f
      setTextIsSelectable(true)
      setPadding(0, 24, 0, 0)
    })
    setContentView(ScrollView(this).apply { addView(content) })
  }

}
