/// How long a persistent session has been running with nobody watching.
///
/// Pure so the wording can be tested without a database or a clock: the resumable list uses it to
/// turn a row into something a user can act on, and "left running 4 minutes ago" versus "left
/// running last month" is the whole difference between resuming and forgetting.
library;

import '../data/app_database.dart';

/// A phrase for [row]'s age, from [now] (defaults to the wall clock).
///
/// `backgroundedAt` is 0 for a session that was created but never closed — it is still open in a
/// tab, or the app died holding it. That is deliberately *not* rendered as "left running in 1970":
/// the honest phrase is that nobody knows.
String describeSessionAge(PersistentSession row, {DateTime? now}) {
  final stamp = row.backgroundedAt;
  if (stamp <= 0) return 'still open, or left behind by a crash';

  final at = DateTime.fromMillisecondsSinceEpoch(stamp);
  final elapsed = (now ?? DateTime.now()).difference(at);
  if (elapsed.isNegative) {
    // The device clock moved backwards between closing and reading. A negative age is not a fact
    // about the session.
    return 'left running';
  }
  if (elapsed.inMinutes < 1) return 'left running just now';
  if (elapsed.inHours < 1) return 'left running ${elapsed.inMinutes}m ago';
  if (elapsed.inDays < 1) return 'left running ${elapsed.inHours}h ago';
  return 'left running ${elapsed.inDays}d ago';
}

/// How long ago a shell session was opened, ported from `formatSessionAge`
/// (`ui/OmniComponents.kt:504`).
///
/// Distinct from `formatUptime`, which reports a *duration the host told us*. This measures against
/// the clock, so it has two cases uptime does not: a session with no recorded start, and one whose
/// start is in the future — which a clock adjustment during a long-lived session can produce, and
/// which must not render as a negative age.
///
/// Zero-padded minutes and hours (`2h 05m`) so the width does not jitter as the number ticks over,
/// matching the Kotlin.
String formatSessionAge(DateTime? startedAt, {DateTime? now}) {
  if (startedAt == null) return '—';
  final elapsed = (now ?? DateTime.now()).difference(startedAt);
  if (elapsed.isNegative) return '—';
  final totalMinutes = elapsed.inMinutes;
  // Under a minute is "just now" rather than "0m": a session opened this second has not been
  // running for zero minutes, it has barely started.
  if (totalMinutes < 1) return 'just now';
  final days = totalMinutes ~/ 1440;
  final hours = (totalMinutes % 1440) ~/ 60;
  final minutes = totalMinutes % 60;
  if (days > 0) return '${days}d ${hours.toString().padLeft(2, '0')}h';
  if (hours > 0) return '${hours}h ${minutes.toString().padLeft(2, '0')}m';
  return '${minutes}m';
}
