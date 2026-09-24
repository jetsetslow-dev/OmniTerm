import 'package:flutter_test/flutter_test.dart';
import 'package:omniterm/data/shares/remote_fs_client.dart';

/// The SFTP retry policy is the part of that client most likely to corrupt data if it is wrong, so
/// it is modelled here as a standalone decision function and tested directly.
///
/// The rule ported from `JschSftp.withPooledChannel`:
///  - a failure *opening* the channel is always retried once, because nothing has happened yet;
///  - a failure *inside* the operation is retried only for metadata reads;
///  - a transfer is **never** retried, because the caller's stream is already partly consumed or
///    written, so a retry duplicates downloaded bytes or uploads only the leftover tail;
///  - a logical error (no such file, permission denied) never evicts the warm connection.
bool shouldRetry({
  required bool duringOpen,
  required bool connectionIsStale,
  required bool retryAllowedForOperation,
  required int attemptsSoFar,
}) {
  if (attemptsSoFar >= 1) return false;
  if (!connectionIsStale) return false;
  return duringOpen || retryAllowedForOperation;
}

bool shouldEvict({required bool connectionIsStale}) => connectionIsStale;

void main() {
  group('retry policy', () {
    test('a stale connection failing at open is retried once', () {
      expect(
        shouldRetry(
          duringOpen: true,
          connectionIsStale: true,
          retryAllowedForOperation: false,
          attemptsSoFar: 0,
        ),
        isTrue,
        reason: 'nothing has happened yet, so a reconnect is free of side effects',
      );
    });

    test('a retry happens at most once', () {
      expect(
        shouldRetry(
          duringOpen: true,
          connectionIsStale: true,
          retryAllowedForOperation: true,
          attemptsSoFar: 1,
        ),
        isFalse,
        reason: 'an endlessly retried command could execute a mutation repeatedly',
      );
    });

    test('a metadata operation on a stale connection is retried', () {
      expect(
        shouldRetry(
          duringOpen: false,
          connectionIsStale: true,
          retryAllowedForOperation: true,
          attemptsSoFar: 0,
        ),
        isTrue,
      );
    });

    test('a transfer is never retried, even on a stale connection', () {
      // The critical case: the caller's sink already holds bytes, or their source is already partly
      // read. Retrying duplicates or truncates the file.
      expect(
        shouldRetry(
          duringOpen: false,
          connectionIsStale: true,
          retryAllowedForOperation: false,
          attemptsSoFar: 0,
        ),
        isFalse,
      );
    });

    test('a logical error on a healthy connection is never retried', () {
      for (final duringOpen in [true, false]) {
        expect(
          shouldRetry(
            duringOpen: duringOpen,
            connectionIsStale: false,
            retryAllowedForOperation: true,
            attemptsSoFar: 0,
          ),
          isFalse,
          reason: 'retrying "No such file" just fails twice',
        );
      }
    });
  });

  group('eviction policy', () {
    test('only a dropped connection is evicted', () {
      expect(shouldEvict(connectionIsStale: true), isTrue);
      expect(
        shouldEvict(connectionIsStale: false),
        isFalse,
        reason: 'a permission error must not throw away the warm authenticated connection',
      );
    });
  });

  group('TransferProgressThrottle', () {
    test('reports an opening zero so the UI can render the row immediately', () {
      final reports = <(int, int)>[];
      TransferProgressThrottle((c, t) => reports.add((c, t)), 100);
      expect(reports, [(0, 100)]);
    });

    test('suppresses reports below both thresholds', () {
      final reports = <(int, int)>[];
      final throttle = TransferProgressThrottle((c, t) => reports.add((c, t)), 1000);
      for (var i = 0; i < 50; i++) {
        throttle.add(1);
      }
      expect(reports, hasLength(1), reason: 'only the opening zero');
    });

    test('emits once the byte threshold is crossed', () {
      final reports = <int>[];
      final throttle = TransferProgressThrottle((c, _) => reports.add(c), 1 << 20);
      throttle.add(64 * 1024);
      expect(reports.last, 64 * 1024);
    });

    test('finish substitutes the observed count when the total was unknown', () {
      final reports = <(int, int)>[];
      final throttle = TransferProgressThrottle((c, t) => reports.add((c, t)), 0);
      throttle.add(42);
      throttle.finish();
      expect(reports.last, (42, 42), reason: 'a completed transfer must not render as partial');
    });

    test('finish keeps a known total', () {
      final reports = <(int, int)>[];
      final throttle = TransferProgressThrottle((c, t) => reports.add((c, t)), 500);
      throttle.add(500);
      throttle.finish();
      expect(reports.last, (500, 500));
    });

    test('a null callback is safe', () {
      final throttle = TransferProgressThrottle(null, 10)..add(5);
      expect(throttle.finish, returnsNormally);
      expect(throttle.copied, 5);
    });
  });
}
