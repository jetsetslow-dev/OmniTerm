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

/// "Started 12m ago", "Started 3h 04m ago" or "Started 2d 07h ago" through [ago], and [justNow]
/// ("Started just now") in the first minute, which [ago] would make "Started just now ago". Ported
/// from `ageText` (`ui/OmniComponents.kt`), and used the same way: a terminal session's start and
/// backgrounding, a tmux session's start, and when a host was last seen.
///
/// [sinceMs] is epoch milliseconds. Distinct from `formatUptime`, which reports a *duration the host
/// told us*: this measures against the clock, so it has two cases uptime does not. No recorded time
/// (0 or less) reads "—", and a time ahead of the clock, which a clock set back produces, counts as
/// just now rather than a negative age.
String ageText(String Function(Object age) ago, String justNow, int sinceMs, {DateTime? now}) {
  final age = _formatAge(sinceMs, now ?? DateTime.now());
  return age == null ? justNow : ago(age);
}

/// The age [ageText] puts in "{a1} ago": `12m`, `3h 04m`, `2d 07h`, or null in the first minute.
///
/// Zero-padded minutes and hours (`2h 05m`) so the width does not jitter as the number ticks over,
/// matching the Kotlin.
String? _formatAge(int sinceMs, DateTime now) {
  if (sinceMs <= 0) return '—';
  final totalMinutes = (now.millisecondsSinceEpoch - sinceMs) ~/ 60000;
  if (totalMinutes < 1) return null;
  final days = totalMinutes ~/ 1440;
  final hours = (totalMinutes % 1440) ~/ 60;
  final minutes = totalMinutes % 60;
  if (days > 0) return '${days}d ${hours.toString().padLeft(2, '0')}h';
  if (hours > 0) return '${hours}h ${minutes.toString().padLeft(2, '0')}m';
  return '${minutes}m';
}
