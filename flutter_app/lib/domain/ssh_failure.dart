/// Turns a transport error string into something worth showing a user.
///
/// Ported from `classifySshConnectionFailure` and `SshConnectionFailure` (`ui/AppViewModel.kt:354`).
/// The transport reports failure by *returning* `'SSH Error: <detail>'`, and the detail is whatever
/// dartssh2 or the socket layer produced — `SSHAuthFailError`, `SocketException: Connection refused
/// (OS Error: Connection refused, errno = 111)`. Correct, and not an answer to "what do I do now".
enum SshFailureKind {
  authentication('Authentication failed (bad key or password)'),
  refused(
    "Connection refused — the server isn't accepting SSH yet (it may still be booting). "
    'Try again in a moment.',
  ),
  timeout("Connection timed out — the host didn't respond. Check it's powered on and reachable."),
  hostNotFound('Host not found — check the hostname or IP address.'),
  networkUnreachable("Network unreachable — the host can't be reached from this network."),
  dropped(
    'Connection dropped during handshake — the server may not be ready yet. Try again in a moment.',
  ),
  hostKey('Host key verification failed.'),
  unknown("Connection failed — the host didn't respond as expected.");

  const SshFailureKind(this.message);

  final String message;
}

/// Classifies [raw], which may or may not carry the `SSH Error:` prefix.
SshFailureKind classifySshFailure(String raw) {
  final message = raw.replaceFirst(RegExp(r'^SSH Error:\s*'), '').trim().toLowerCase();
  bool has(List<String> needles) => needles.any(message.contains);

  // Both spellings on purpose: Compose classifies JSch's wording ("Auth fail", "USERAUTH fail")
  // and this port sees dartssh2's (`SSHAuthFailError`, `SSHAuthAbortError`) — no space, different
  // words. Porting the needles verbatim would have matched nothing at all.
  if (has([
    'auth fail',
    'auth cancel',
    'userauth fail',
    'sshauthfail',
    'sshauthabort',
    'authentication failed',
  ])) {
    return SshFailureKind.authentication;
  }
  if (has(['connection refused'])) return SshFailureKind.refused;
  if (has(['timed out', 'timeout', 'socket is not established', 'connection timed'])) {
    return SshFailureKind.timeout;
  }
  if (has([
    'unknownhost',
    'name or service not known',
    'nodename nor servname',
    'no address associated',
    'failed host lookup',
  ])) {
    return SshFailureKind.hostNotFound;
  }
  if (has(['network is unreachable', 'no route to host'])) {
    return SshFailureKind.networkUnreachable;
  }
  if (has(['connection reset', 'broken pipe', 'connection closed by', 'sshchannelopenerror'])) {
    return SshFailureKind.dropped;
  }
  if (has(['reject hostkey', 'hostkey has been changed', 'host key'])) {
    return SshFailureKind.hostKey;
  }
  return SshFailureKind.unknown;
}

/// Whether [raw] proves that no SSH endpoint could be reached.
///
/// Authentication and host-key failures happen only after an SSH server answers, while dropped or
/// unknown failures are too ambiguous to justify blocking the user's connection attempt. Keep this
/// deliberately narrow: a background check is advisory, not an authority over the real SSH path.
bool sshFailureProvesEndpointUnreachable(String raw) => switch (classifySshFailure(raw)) {
  SshFailureKind.refused ||
  SshFailureKind.timeout ||
  SshFailureKind.hostNotFound ||
  SshFailureKind.networkUnreachable => true,
  SshFailureKind.authentication ||
  SshFailureKind.dropped ||
  SshFailureKind.hostKey ||
  SshFailureKind.unknown => false,
};

/// A user-facing sentence for [raw].
///
/// An unrecognised failure keeps its own detail rather than being flattened into "something went
/// wrong": the detail is the only thing that distinguishes one unknown from another when someone
/// reports it.
String describeSshFailure(String raw) {
  final kind = classifySshFailure(raw);
  if (kind != SshFailureKind.unknown) return kind.message;
  final detail = raw.replaceFirst(RegExp(r'^SSH Error:\s*'), '').trim();
  return detail.isEmpty ? kind.message : detail;
}
