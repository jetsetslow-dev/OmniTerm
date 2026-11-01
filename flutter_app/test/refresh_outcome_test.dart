import 'package:flutter_test/flutter_test.dart';
import 'package:omniterm/domain/refresh_outcome.dart';

/// Mirror of Kotlin's `RefreshOutcomeTest`. A pull-to-refresh that ends badly has to say so: the
/// regression this guards is a host left on the "Checking host…" spinner forever while the refresh
/// reported nothing at all.
void main() {
  RefreshHostState host({
    String name = 'atlas',
    String status = 'online',
    bool probed = true,
    String authStatus = 'ok',
    String? authError,
  }) => RefreshHostState(
    name: name,
    status: status,
    probed: probed,
    authStatus: authStatus,
    authError: authError,
  );

  test('a healthy fleet reports nothing', () {
    expect(describeRefreshOutcome([host(), host(name: 'beta')], waitedSeconds: 30), isNull);
  });

  test('no hosts reports nothing', () {
    expect(describeRefreshOutcome(const [], waitedSeconds: 30), isNull);
  });

  test('a host still marked connecting is reported, not left silent', () {
    expect(
      describeRefreshOutcome([host(status: 'connecting')], waitedSeconds: 30),
      'Refresh problem on 1 host(s): atlas is still not answering after 30s',
    );
  });

  test('a host that never completed a probe is reported even when the row says online', () {
    // The exact stranding: the status column is not "connecting" but the row still renders the
    // spinner because no probe ever reached a verdict for it.
    expect(isStillChecking(host(probed: false)), isTrue);
    expect(
      describeRefreshOutcome([host(probed: false)], waitedSeconds: 30),
      'Refresh problem on 1 host(s): atlas is still not answering after 30s',
    );
  });

  test('an offline host is reported as not responding on its route', () {
    expect(
      describeRefreshOutcome([host(status: 'offline')], waitedSeconds: 30),
      'Refresh problem on 1 host(s): atlas did not respond on its configured SSH route',
    );
  });

  test('an auth failure surfaces the classified error', () {
    expect(
      describeRefreshOutcome([
        host(authStatus: 'failed', authError: 'Permission denied (publickey).'),
      ], waitedSeconds: 30),
      'Refresh problem on 1 host(s): atlas: Permission denied (publickey).',
    );
  });

  test('an auth failure with no message still says something useful', () {
    expect(
      describeRefreshOutcome([host(authStatus: 'failed')], waitedSeconds: 30),
      'Refresh problem on 1 host(s): atlas: SSH authentication failed.',
    );
  });

  test('still-checking wins over a stale auth failure on the same host', () {
    expect(
      describeRefreshOutcome([
        host(status: 'connecting', authStatus: 'failed', authError: 'old error'),
      ], waitedSeconds: 30),
      'Refresh problem on 1 host(s): atlas is still not answering after 30s',
    );
  });

  test('every failing host is named and counted', () {
    expect(
      describeRefreshOutcome([
        host(name: 'good'),
        host(name: 'slow', status: 'connecting'),
        host(name: 'down', status: 'offline'),
      ], waitedSeconds: 30),
      'Refresh problem on 2 host(s): slow is still not answering after 30s; '
      'down did not respond on its configured SSH route',
    );
  });
}
