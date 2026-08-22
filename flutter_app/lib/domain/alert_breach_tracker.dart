/// Sustained-breach window tracker for alert rules, keyed by (ruleId, serverId).
///
/// Ported from `ui/AlertBreachTracker.kt`. Two behaviours make triggering consistent where the
/// naive "reset on any clean sample" approach was not:
///  - **Hysteresis:** a single under-threshold sample (metric jitter) neither resets the breach
///    window nor resolves an active incident; it takes [resetAfterUnderSamples] consecutive clean
///    samples.
///  - **Gap restart:** when sampling stops mid-breach (app paused, battery saver, host
///    unreachable), wall-clock time keeps passing but nothing was observed. A sample arriving after
///    more than the stale gap restarts the window instead of instantly firing on the accumulated
///    time.
///
/// The Kotlin used a `ConcurrentHashMap`. A plain [Map] is correct here: Dart isolates are
/// single-threaded, so there is no concurrent mutation to guard against, and no `await` occurs
/// between the read and the write inside [onSample].
library;

class _BreachState {
  _BreachState({required this.since, required this.lastSeen});

  int since;
  int lastSeen;
  int underStreak = 0;
}

/// Identity of one rule's incident on one concrete host.
typedef BreachKey = (int ruleId, int serverId);

class AlertBreachTracker {
  /// Consecutive under-threshold samples required before a breach window is discarded.
  static const resetAfterUnderSamples = 2;

  final Map<BreachKey, _BreachState> _states = {};

  /// Feed one sample; returns true when the breach has been sustained for [windowMs].
  bool onSample(
    BreachKey key, {
    required bool over,
    required int now,
    required int windowMs,
    required int staleGapMs,
  }) {
    final existing = _states[key];

    if (!over) {
      if (existing != null) {
        existing.lastSeen = now;
        existing.underStreak++;
        if (existing.underStreak >= resetAfterUnderSamples) _states.remove(key);
      }
      return false;
    }

    final _BreachState state;
    if (existing == null) {
      state = _BreachState(since: now, lastSeen: now);
      _states[key] = state;
    } else if (now - existing.lastSeen > staleGapMs) {
      // Nothing was observed across the gap, so the elapsed wall-clock time is not evidence of a
      // sustained breach — restart the window rather than firing on it.
      existing.since = now;
      state = existing;
    } else {
      state = existing;
    }

    state.lastSeen = now;
    state.underStreak = 0;
    return now - state.since >= windowMs;
  }

  /// True when an active incident may resolve: the breach state is fully cleared (enough
  /// consecutive clean samples, or no breach was ever observed this app run).
  bool clearedFor(BreachKey key) => !_states.containsKey(key);

  /// Drop tracked state, e.g. when the rule is deleted or its incident is dismissed.
  void forget(BreachKey key) => _states.remove(key);

  /// Drop every host window for a rule after that rule is deleted or materially edited.
  void forgetRule(int ruleId) {
    _states.removeWhere((key, _) => key.$1 == ruleId);
  }
}
