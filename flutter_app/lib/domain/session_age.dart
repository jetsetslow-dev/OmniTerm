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
