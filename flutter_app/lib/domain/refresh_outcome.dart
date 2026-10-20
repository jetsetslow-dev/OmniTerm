/// One host's state exactly as the Servers list renders it, so a pull-to-refresh can report on the
/// same thing the user is looking at.
///
/// [probed] mirrors `HostStatusProbe.hasProbed`: a host that has never completed a probe shows the
/// "Checking host…" spinner regardless of the status column, because the stored `offline` is only
/// the startup default at that point.
///
/// Ported from `data/RefreshOutcome.kt`; the wording is deliberately identical in both apps.
class RefreshHostState {
  const RefreshHostState({
    required this.name,
    required this.status,
    required this.probed,
    required this.authStatus,
    this.authError,
  });

  final String name;
  final String status;
  final bool probed;
  final String authStatus;
  final String? authError;
}

/// True while the row would still render the "Checking host…" spinner.
bool isStillChecking(RefreshHostState host) => host.status == 'connecting' || !host.probed;

/// Turns the post-refresh state of the fleet into the one sentence the user should be told, or null
/// when everything is fine.
///
/// It exists because a pull-to-refresh used to report nothing at all: a host whose probe never
/// reached a verdict simply sat on "Checking host…" indefinitely with no error and nothing to
/// retry, which reads as the app being broken rather than the host being slow.
String? describeRefreshOutcome(List<RefreshHostState> hosts, {required int waitedSeconds}) {
  final problems = <String>[];
  for (final h in hosts) {
    if (isStillChecking(h)) {
      problems.add('${h.name} is still not answering after ${waitedSeconds}s');
    } else if (h.status == 'offline') {
      problems.add('${h.name} did not respond on its configured SSH route');
    } else if (h.authStatus == 'failed') {
      problems.add('${h.name}: ${h.authError ?? 'SSH authentication failed.'}');
    }
  }
  if (problems.isEmpty) return null;
  return 'Refresh problem on ${problems.length} host(s): ${problems.join('; ')}';
}
