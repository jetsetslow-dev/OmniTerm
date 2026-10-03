import 'package:flutter_test/flutter_test.dart';
import 'package:omniterm/domain/transfer_aggregate.dart';

/// Overall transfer progress, ported from `TransferAggregate` / `transferAggregate`
/// (`ui/AppViewModel.kt:498`, `:9874`).
///
/// Flutter drew a bar per file and nothing above them, which answers "is this file moving?" but
/// never "how far through the batch am I, and how long is left" — the only question worth asking
/// while a folder copies.
void main() {
  TransferProgress running({int done = 0, int total = 0, double speed = 0}) =>
      TransferProgress(bytesTransferred: done, totalBytes: total, speedKbps: speed);

  group('aggregateTransfers', () {
    test('nothing running means nothing to show', () {
      expect(aggregateTransfers(const []), isNull);
    });

    test('bytes, totals and speeds add up across files', () {
      final agg = aggregateTransfers([
        running(done: 100, total: 400, speed: 512),
        running(done: 300, total: 600, speed: 512),
      ])!;

      expect(agg.activeFiles, 2);
      expect(agg.bytesTransferred, 400);
      expect(agg.totalBytes, 1000);
      expect(agg.speedKbps, 1024);
      expect(agg.fraction, 0.4);
    });

    test('a file of unknown size does not drag the total down', () {
      // Its bytes still count as progress, but it contributes no denominator — otherwise a nearly
      // finished batch would render as barely started.
      final agg = aggregateTransfers([running(done: 900, total: 1000), running(done: 50)])!;

      expect(agg.totalBytes, 1000);
      expect(agg.bytesTransferred, 950);
      expect(agg.hasKnownTotal, isTrue);
    });

    test('no sizes at all means an indeterminate bar, not zero percent', () {
      // A determinate bar pinned at 0% reads as stalled, which is the opposite of the truth.
      final agg = aggregateTransfers([running(done: 5000)])!;

      expect(agg.hasKnownTotal, isFalse);
      expect(agg.fraction, 0);
    });

    test('the fraction cannot exceed one', () {
      // A server that under-reports a size would otherwise produce a bar past its own end.
      final agg = aggregateTransfers([running(done: 2000, total: 1000)])!;
      expect(agg.fraction, 1.0);
    });

    test('a negative byte count is ignored rather than subtracted', () {
      final agg = aggregateTransfers([
        running(done: -10, total: 100),
        running(done: 40, total: 100),
      ])!;
      expect(agg.bytesTransferred, 40);
    });
  });

  group('etaSeconds', () {
    test('estimates from the aggregate speed', () {
      // 1024 KB/s = 1 MB/s, 2 MB remaining.
      final agg = aggregateTransfers([running(done: 0, total: 2 * 1024 * 1024, speed: 1024)])!;
      expect(agg.etaSeconds, 2);
    });

    test('is -1 when nothing is moving, not zero', () {
      // Zero would render as "finishing now"; unknown and nearly-done must not look the same.
      final agg = aggregateTransfers([running(done: 10, total: 100)])!;
      expect(agg.etaSeconds, -1);
    });

    test('is -1 once there is nothing left', () {
      final agg = aggregateTransfers([running(done: 100, total: 100, speed: 512)])!;
      expect(agg.etaSeconds, -1);
    });
  });

  group('formatEta', () {
    test('seconds, minutes and hours read naturally', () {
      expect(formatEta(45), '45s');
      expect(formatEta(120), '2m');
      expect(formatEta(3600), '1h');
      expect(formatEta(3900), '1h 5m');
    });
  });

  group('formatSpeed', () {
    test('switches to MB/s past a megabyte', () {
      expect(formatSpeed(2048), '2.0 MB/s');
      expect(formatSpeed(512), '512 KB/s');
    });

    test('says nothing at all when nothing is moving', () {
      // Better than "0 KB/s", which reads as a stalled transfer rather than one just starting.
      expect(formatSpeed(0), '');
    });
  });
}
