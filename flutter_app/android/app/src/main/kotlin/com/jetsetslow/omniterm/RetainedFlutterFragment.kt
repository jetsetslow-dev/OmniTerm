package com.jetsetslow.omniterm

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
}
