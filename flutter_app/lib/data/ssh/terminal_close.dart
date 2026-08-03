/// Classification of how an interactive shell channel ended.
///
/// Ported from `classifyTerminalClose` in `data/ssh/JschSshTransport.kt`, kept as a standalone pure
/// function precisely because it is the decision that matters most and the easiest to get wrong.
///
/// A real shell/tmux exit should tear the app session down. A transport loss should keep the app
/// session around and reconnect, especially for tmux-backed sessions where the remote process keeps
/// running. Both look alike at the stream level — each ends the read loop — so EOF alone is not
/// strong enough evidence: during a network handoff the socket can already be gone and no
/// exit-status will ever arrive.
library;

class TerminalCloseClassification {
  const TerminalCloseClassification({required this.remoteExited, required this.exitStatus});

  final bool remoteExited;
  final int? exitStatus;

  @override
  bool operator ==(Object other) =>
      other is TerminalCloseClassification &&
      other.remoteExited == remoteExited &&
      other.exitStatus == exitStatus;

  @override
  int get hashCode => Object.hash(remoteExited, exitStatus);

  @override
  String toString() =>
      'TerminalCloseClassification(remoteExited: $remoteExited, exitStatus: $exitStatus)';
}

/// Decide whether the remote deliberately ended the shell.
///
/// [remoteEof] — the read loop ended because the remote closed the stream gracefully, rather than
/// because we closed it or the connection dropped mid-read.
/// [channelIsEof] — the channel itself reports a clean EOF.
/// [sessionConnected] — the underlying transport is still up, which distinguishes "the shell exited
/// but the connection is fine" from "everything went away at once".
/// [exitStatus] — the numeric status if the server sent one; commonly `-1` or null after a drop.
///
/// A clean exit is normalised to status 0 when the status message never arrived, because a graceful
/// EOF on a live session *is* a completed shell. A drop is never normalised: doing so would make a
/// network handoff look like `exit` and kill a session that should have reconnected.
TerminalCloseClassification classifyTerminalClose({
  required bool remoteEof,
  required bool channelIsEof,
  required bool sessionConnected,
  required int? exitStatus,
}) {
  final hasRealExitStatus = exitStatus != null && exitStatus >= 0;
  final cleanRemoteExit = remoteEof && channelIsEof && (hasRealExitStatus || sessionConnected);
  final normalizedExitStatus =
      (cleanRemoteExit && !hasRealExitStatus) ? 0 : exitStatus;
  return TerminalCloseClassification(
    remoteExited: cleanRemoteExit,
    exitStatus: normalizedExitStatus,
  );
}
