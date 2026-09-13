package com.jetsetslow.omniterm

import android.content.Context
import io.flutter.embedding.engine.FlutterEngine

/**
 * The one Flutter engine this process uses, kept alive across Activity instances.
 *
 * A default [io.flutter.embedding.android.FlutterActivity] creates its engine in `onCreate` and
 * destroys it in `onDestroy`, so any Activity recreation — a rotation, a theme or font-scale
 * change, a system-initiated restart — tears down the Dart isolate. In this app that isolate *owns
 * the SSH sessions*: the foreground service keeps the process alive, but nothing kept the sessions
 * alive, so every shell died on a configuration change while the notification still claimed they
 * were running.
 *
 * Retention is done through `provideFlutterEngine` rather than [io.flutter.embedding.engine
 * .FlutterEngineCache]: the cached-engine path throws if the cache is empty and would need the
 * engine pre-populated from an Application subclass, while `provideFlutterEngine` lets the first
 * Activity create it lazily. The embedding then sets `isFlutterEngineFromHost`, which makes
 * `shouldDestroyEngineWithHost()` false, and skips re-running the Dart entrypoint because the
 * isolate is already executing (`FlutterActivityAndFragmentDelegate.doInitialFlutterViewRun`).
 *
 * The engine outliving its Activity is the entire point, so the exit path has to be explicit:
 * [destroy] is what "Terminate & Exit" calls, because finishing the Activity no longer ends
 * anything on its own.
 */
object RetainedFlutterEngine {
    private var engine: FlutterEngine? = null

    /** The process-wide engine, created on first use. */
    fun obtain(context: Context): FlutterEngine =
        engine ?: FlutterEngine(context.applicationContext).also { engine = it }

    /** The current engine without creating one, for callers that only act when one exists. */
    fun peek(): FlutterEngine? = engine

    /**
     * Ends the Dart isolate and everything it owns.
     *
     * Only for an explicit user exit. The Quit dialog promises that exiting terminates active
     * background SSH sessions, and with the engine retained, finishing the Activity no longer
     * keeps that promise by itself.
     */
    fun destroy() {
        engine?.destroy()
        engine = null
    }
}
