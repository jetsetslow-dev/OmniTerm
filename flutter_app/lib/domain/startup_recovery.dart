/// Whether to offer recovery instead of launching into the same crash again.
///
/// Ported from `MainActivity.onCreate`'s crash gate (`MainActivity.kt:55`–`:70`).
///
/// Flutter records crashes and lists them under About, but nothing guarded *startup*: an exception
/// while opening the database or restoring settings killed the app before any UI existed, and the
/// next launch did the same. On a device the only way out is clearing app data, which throws away
/// every saved host to escape a problem the user cannot see.
library;

/// How long a startup crash keeps offering recovery, matching Kotlin's seven days.
///
/// Bounded rather than forever: a report from months ago is not evidence about this launch, and a
/// recovery screen that will not go away is its own kind of broken app.
const Duration startupCrashTtl = Duration(days: 7);

/// What to do with a recorded startup crash on the next launch.
enum StartupCrashVerdict {
  /// No crash recorded, so start normally.
  none,

  /// Recent enough to be about this install — show recovery instead of launching.
  offerRecovery,

  /// Older than the TTL. Start normally, and clear the record on the way past so it cannot
  /// resurface later looking current.
  stale,
}

/// Classifies a recorded startup crash.
///
/// [recordedAtMs] is wall-clock, so a device whose clock moved backwards can make a real crash look
/// like it happened in the future. That is treated as **recent**, not stale: erring toward offering
/// a way out is the safe direction when the alternative is relaunching into a crash.
StartupCrashVerdict classifyStartupCrash({
  required String? report,
  required int recordedAtMs,
  required int nowMs,
}) {
  if (report == null || report.trim().isEmpty) return StartupCrashVerdict.none;
  if (recordedAtMs <= 0) return StartupCrashVerdict.stale;
  final age = nowMs - recordedAtMs;
  if (age < 0) return StartupCrashVerdict.offerRecovery;
  return age < startupCrashTtl.inMilliseconds
      ? StartupCrashVerdict.offerRecovery
      : StartupCrashVerdict.stale;
}
