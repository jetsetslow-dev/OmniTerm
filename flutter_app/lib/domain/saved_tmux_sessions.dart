/// Ending and accounting for the tmux sessions OmniTerm keeps on saved hosts, ported from
/// `ui/SavedTmuxSessions.kt`.
library;

/// How an attempt to end a tmux session on its server turned out.
sealed class TmuxEndResult {
  const TmuxEndResult();
}

final class TmuxEnded extends TmuxEndResult {
  const TmuxEnded();
}

/// The server could not be reached (or refused the login); [reason] is the transport's reply.
final class TmuxUnreachable extends TmuxEndResult {
  const TmuxUnreachable(this.reason);

  final String reason;
}

/// The server answered, but tmux did not confirm the session is gone.
final class TmuxNotConfirmed extends TmuxEndResult {
  const TmuxNotConfirmed();
}

/// Runs [kill], then asks tmux whether the session still exists. Only a confirmed absence counts
/// as ended: a kill that seemed to work but cannot be checked leaves the session saved, so nothing
/// still running on a server is ever forgotten by accident.
Future<TmuxEndResult> endRemoteTmux({
  required Future<String> Function() kill,
  required Future<bool?> Function() stillExists,
}) async {
  final reply = (await kill()).trim();
  if (reply.startsWith('SSH Error')) return TmuxUnreachable(reply);
  return await stillExists() == false ? const TmuxEnded() : const TmuxNotConfirmed();
}
