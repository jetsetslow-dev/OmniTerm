import 'package:flutter_test/flutter_test.dart';
import 'package:omniterm/data/remote_models.dart';
import 'package:omniterm/domain/telemetry_sampling.dart';

void main() {
  /// A probe reply carrying only the counter sections the sampler reads. The `@` markers are the
  /// real ones `metricsLinux` emits and `parseMetrics` splits on.
  String probe({
    required int cpuIdle,
    required int cpuTotal,
    List<(int idle, int total)> cores = const [],
    Map<String, (int rx, int tx)> net = const {},
    Map<String, (int read, int write)> disk = const {},
  }) {
    final lines = <String>[
      '@CPUSTAT',
      // /proc/stat columns: user nice system idle iowait. The sampler wants idle+iowait and the sum.
      'cpu 0 0 ${cpuTotal - cpuIdle} $cpuIdle 0',
      for (var i = 0; i < cores.length; i++)
        'cpu$i 0 0 ${cores[i].$2 - cores[i].$1} ${cores[i].$1} 0',
      '@NETDEV',
      for (final e in net.entries) '${e.key}: ${e.value.$1} 0 0 0 0 0 0 0 ${e.value.$2}',
      '@DISKIO',
      // /proc/diskstats: major minor name, then reads at [5] and writes at [9], in 512B sectors.
      for (final e in disk.entries)
        '8 0 ${e.key} 0 0 ${e.value.$1 ~/ 512} 0 0 0 ${e.value.$2 ~/ 512} 0 0 0',
    ];
    return lines.join('\n');
  }

  const parsed = HostMetrics(
    cpuPercent: 42,
    memUsedBytes: 1,
    memTotalBytes: 2,
    diskUsedBytes: 1,
    diskTotalBytes: 2,
    load1: 0,
    load5: 0,
    load15: 0,
    uptimeSeconds: 100,
    procCount: 10,
  );

  TelemetrySample sample(String raw, {TelemetryBaseline? previous, int nowMs = 0}) =>
      enrichMetrics(parsed: parsed, raw: raw, nowMs: nowMs, previous: previous);

  group('the first probe of a host', () {
    test('reports no rates rather than zeros that look measured', () {
      final first = sample(
        probe(cpuIdle: 900, cpuTotal: 1000, net: {'eth0': (1000, 500)}),
        nowMs: 0,
      );

      expect(first.metrics.netRxPerSec, 0);
      expect(first.metrics.diskReadPerSec, 0);
      expect(first.metrics.perCoreCpu, isEmpty);
    });

    test('keeps the CPU figure the host itself reported', () {
      // There is no window to measure, and 0% would say the machine is idle. `top`'s own number is
      // the only reading anyone has.
      expect(sample(probe(cpuIdle: 900, cpuTotal: 1000)).metrics.cpuPercent, 42);
    });

    test('still carries the counters forward so the next probe can measure', () {
      expect(sample(probe(cpuIdle: 900, cpuTotal: 1000)).baseline, isNotNull);
    });
  });

  group('the second probe', () {
    test('derives CPU busy percent from the jiffy delta, not from top', () {
      // 100 jiffies passed, 25 of them idle → 75% busy. `parsed` says 42, and the measured figure
      // is the one that wins.
      final first = sample(probe(cpuIdle: 900, cpuTotal: 1000), nowMs: 0);
      final second = sample(
        probe(cpuIdle: 925, cpuTotal: 1100),
        previous: first.baseline,
        nowMs: 15000,
      );

      expect(second.metrics.cpuPercent, closeTo(75, 0.001));
    });

    test('derives one figure per core', () {
      final first = sample(
        probe(cpuIdle: 0, cpuTotal: 0, cores: [(100, 200), (100, 200)]),
        nowMs: 0,
      );
      final second = sample(
        probe(cpuIdle: 0, cpuTotal: 0, cores: [(150, 300), (100, 300)]),
        previous: first.baseline,
        nowMs: 15000,
      );

      // Core 0: 50 idle of 100 → 50%. Core 1: 0 idle of 100 → 100%.
      expect(second.metrics.perCoreCpu, [closeTo(50, 0.001), closeTo(100, 0.001)]);
    });

    test('turns interface byte counters into per-second rates', () {
      final first = sample(probe(cpuIdle: 0, cpuTotal: 0, net: {'eth0': (1000, 500)}), nowMs: 0);
      final second = sample(
        probe(cpuIdle: 0, cpuTotal: 0, net: {'eth0': (16000, 8000)}),
        previous: first.baseline,
        nowMs: 15000,
      );

      // 15000 bytes over 15 seconds.
      expect(second.metrics.netInterfaces.single.rxPerSec, 1000);
      expect(second.metrics.netInterfaces.single.txPerSec, 500);
      expect(second.metrics.netRxPerSec, 1000, reason: 'the headline figure sums the interfaces');
    });

    test('sums disk throughput across devices', () {
      final first = sample(
        probe(cpuIdle: 0, cpuTotal: 0, disk: {'sda': (1024, 0), 'sdb': (0, 512)}),
        nowMs: 0,
      );
      final second = sample(
        probe(cpuIdle: 0, cpuTotal: 0, disk: {'sda': (11264, 0), 'sdb': (0, 5632)}),
        previous: first.baseline,
        nowMs: 10000,
      );

      expect(second.metrics.diskReadPerSec, 1024);
      expect(second.metrics.diskWritePerSec, 512);
    });
  });

  group('a counter that goes backwards', () {
    // The host rebooted, the interface was recreated, the disk was re-attached. Every counter
    // restarts near zero and `current - previous` is a large negative number.
    test('reports no throughput rather than a negative one', () {
      final first = sample(
        probe(
          cpuIdle: 0,
          cpuTotal: 0,
          net: {'eth0': (900000000, 900000000)},
          disk: {'sda': (900000000, 900000000)},
        ),
        nowMs: 0,
      );
      final second = sample(
        probe(cpuIdle: 0, cpuTotal: 0, net: {'eth0': (1000, 500)}, disk: {'sda': (1024, 512)}),
        previous: first.baseline,
        nowMs: 15000,
      );

      expect(second.metrics.netInterfaces.single.rxPerSec, 0);
      expect(second.metrics.netInterfaces.single.txPerSec, 0);
      expect(second.metrics.diskReadPerSec, 0);
      expect(second.metrics.diskWritePerSec, 0);
    });

    test('the rebooted host measures normally again on the next probe', () {
      // The zeroed window must not poison the baseline: the counters after the reboot are the ones
      // the next window is measured against.
      final first = sample(probe(cpuIdle: 0, cpuTotal: 0, net: {'eth0': (900000, 0)}), nowMs: 0);
      final reboot = sample(
        probe(cpuIdle: 0, cpuTotal: 0, net: {'eth0': (100, 0)}),
        previous: first.baseline,
        nowMs: 15000,
      );
      final after = sample(
        probe(cpuIdle: 0, cpuTotal: 0, net: {'eth0': (15100, 0)}),
        previous: reboot.baseline,
        nowMs: 30000,
      );

      expect(after.metrics.netInterfaces.single.rxPerSec, 1000);
    });
  });

  group('two probes too close together', () {
    // A manual refresh landing right after a scheduled poll. The window is a fraction of a second
    // and dividing by it turns rounding noise into a spike that never happened.
    late TelemetrySample first;
    late TelemetrySample second;
    late TelemetrySample immediate;

    setUp(() {
      first = sample(
        probe(cpuIdle: 900, cpuTotal: 1000, net: {'eth0': (0, 0)}, disk: {'sda': (0, 0)}),
        nowMs: 0,
      );
      second = sample(
        probe(
          cpuIdle: 925,
          cpuTotal: 1100,
          net: {'eth0': (15000, 15000)},
          disk: {'sda': (15360, 15360)},
        ),
        previous: first.baseline,
        nowMs: 15000,
      );
      immediate = sample(
        probe(
          cpuIdle: 925,
          cpuTotal: 1101,
          net: {'eth0': (15100, 15100)},
          disk: {'sda': (15872, 15872)},
        ),
        previous: second.baseline,
        nowMs: 15100,
      );
    });

    test('repeats the last measured rates instead of inventing new ones', () {
      // 100 bytes in 100ms is 1000 B/s and happens to be right here, but the same arithmetic on a
      // counter that ticked once turns a single 512-byte sector into 5 KB/s of disk traffic.
      expect(immediate.metrics.netInterfaces.single.rxPerSec, second.metrics.netRxPerSec);
      expect(immediate.metrics.diskReadPerSec, second.metrics.diskReadPerSec);
      expect(immediate.metrics.cpuPercent, second.metrics.cpuPercent);
    });

    test('does not become the baseline', () {
      // Otherwise every future window would be measured from a moment that was never measurable,
      // and someone tapping refresh repeatedly would never see a rate again.
      expect(immediate.baseline, isNull);
    });

    test('a clock that jumped backwards is treated the same way', () {
      final backwards = sample(
        probe(cpuIdle: 950, cpuTotal: 1200, net: {'eth0': (16000, 16000)}),
        previous: second.baseline,
        nowMs: 5000,
      );

      expect(backwards.baseline, isNull);
      expect(backwards.metrics.netInterfaces.single.rxPerSec, second.metrics.netRxPerSec);
    });
  });

  test('a host with no /proc keeps the totals its own tools reported', () {
    // BSD and macOS have no /proc/net/dev; their probes carry netstat totals, which parseMetrics
    // has already put in the parsed sample. Replacing those with an empty list blanks the network
    // panel on every Mac.
    const bsd = HostMetrics(
      cpuPercent: 12,
      memUsedBytes: 1,
      memTotalBytes: 2,
      diskUsedBytes: 1,
      diskTotalBytes: 2,
      load1: 0,
      load5: 0,
      load15: 0,
      uptimeSeconds: 1,
      procCount: 1,
      netInterfaces: [NetInterface('en0', 10, 20)],
    );

    final result = enrichMetrics(parsed: bsd, raw: '@OS\nDarwin\n', nowMs: 0);

    expect(result.metrics.netInterfaces.single.name, 'en0');
    expect(result.metrics.cpuPercent, 12);
  });
}
