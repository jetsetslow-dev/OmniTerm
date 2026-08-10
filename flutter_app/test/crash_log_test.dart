import 'package:flutter_test/flutter_test.dart';
import 'package:omniterm/platform/crash_log.dart';

void main() {
  test('redacts secrets, identities, addresses, and private keys', () {
    final safe = redactCrashReport('''
password=hunter2 token: abc123
Authorization: Bearer secret-token
ssh://alice:password@192.168.1.44/home/alice/file
-----BEGIN OPENSSH PRIVATE KEY-----
secret material
-----END OPENSSH PRIVATE KEY-----
''');

    expect(safe, isNot(contains('hunter2')));
    expect(safe, isNot(contains('abc123')));
    expect(safe, isNot(contains('secret-token')));
    expect(safe, isNot(contains('alice')));
    expect(safe, isNot(contains('192.168.1.44')));
    expect(safe, isNot(contains('secret material')));
    expect(safe, contains('<redacted-private-key>'));
    expect(safe, contains('<redacted-ip>'));
  });

  test('headline skips the environment and stack frames', () {
    expect(
      crashHeadline('''
App version: 1.2.3 (42)
Platform: Android 17
Thread: Flutter framework
StateError: broken state
#0 Widget.build
'''),
      'StateError: broken state',
    );
  });

  test('headline is bounded for the About list', () {
    final headline = crashHeadline('E' * 300);
    expect(headline, hasLength(200));
  });

  test('restored crash history is sanitized, deduplicated, capped, and expires', () async {
    final log = CrashLog();
    final now = DateTime.now().millisecondsSinceEpoch;
    final duplicate = CrashEntry(timeMs: now, report: 'password=hunter2\nboom');
    final imported = await log.merge([
      duplicate,
      duplicate,
      CrashEntry(timeMs: now - CrashLog.ttl.inMilliseconds, report: 'expired'),
      for (var index = 1; index <= CrashLog.maxEntries + 5; index++)
        CrashEntry(timeMs: now - index, report: 'failure $index'),
    ]);

    expect(log.entries, hasLength(CrashLog.maxEntries));
    expect(log.entries.where((entry) => entry.timeMs == now), hasLength(1));
    expect(log.entries.any((entry) => entry.report.contains('hunter2')), isFalse);
    expect(log.entries.any((entry) => entry.report == 'expired'), isFalse);
    expect(imported, CrashLog.maxEntries);
    log.dispose();
  });
}
