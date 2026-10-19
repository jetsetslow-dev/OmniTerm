package com.jetsetslow.omniterm

import android.os.Build
import android.os.Bundle
import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import io.flutter.embedding.android.FlutterFragment

/** The engine belongs to RetainedFlutterEngine, not this replaceable Android Fragment.
 *
 * FlutterFragmentActivity's new-engine builder explicitly sets destruction to true, even when
 * provideFlutterEngine later supplies our existing engine. The Activity-level destruction hook
 * only configures the cached-engine builder, so overriding that hook alone does not protect SSH.
 * Keep a public no-argument Fragment so Android restores this policy after Activity recreation.
 */
class RetainedFlutterFragment : FlutterFragment() {
    override fun shouldDestroyEngineWithHost(): Boolean = false

    override fun onCreateView(
        inflater: LayoutInflater,
        container: ViewGroup?,
        savedInstanceState: Bundle?,
    ): View? = super.onCreateView(inflater, container, savedInstanceState)?.also { view ->
        // The FlutterView is one focused, full-screen View. Once a hardware key ends touch mode,
        // Android paints its default focus highlight over it, which covers the SurfaceView Flutter
        // renders into and greys the whole app; the view never redraws itself, so the grey stays
        // until the window is recreated. Flutter draws its own focus indicators, and Compose turns
        // the platform highlight off on its root view in the same way.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) view.defaultFocusHighlightEnabled = false
    }
}
