/// Turning two raw metric probes into rates, ported from the delta arithmetic inside
/// `probeServerInner` in `ui/AppViewModel.kt`.
///
/// A host reports **cumulative counters**: jiffies since boot, bytes since the interface came up,
/// sectors since the disk was attached. None of those is a rate, and every rate the Monitor screen
/// shows — CPU percent, per-core percent, network throughput, disk throughput — is the difference
/// between two probes divided by the time between them. That arithmetic is the part that can be
/// wrong in ways nobody notices (a reboot makes a counter go backwards, a manual refresh makes the
/// window nearly zero), so it lives here as plain functions rather than inside the poller's IO —
/// convention 3.
library;

import '../data/remote_models.dart';
import '../data/remote_parsers.dart';

/// The counters kept from one probe so the next can be turned into rates.
///
/// [takenAtMs] is the phone's clock, not the host's: the counters come from the host but the
/// interval between two reads is measured locally, which is the only clock both samples share.
class TelemetryBaseline {
  const TelemetryBaseline({
    required this.takenAtMs,
    required this.cpu,
    required this.net,
    required this.disk,
    this.netRates = const {},
    this.diskReadPerSec = 0,
    this.diskWritePerSec = 0,
    this.cpuPercent,
  });

  final int takenAtMs;
  final Map<String, (int idle, int total)> cpu;
  final Map<String, (int rx, int tx)> net;
  final Map<String, DiskIo> disk;

  /// The rates this baseline's own sample reported, so a probe that lands too soon to measure a new
  /// window can repeat the last measurement instead of inventing one. See [minimumWindow].
  final Map<String, (int rx, int tx)> netRates;
  final int diskReadPerSec;
  final int diskWritePerSec;
  final double? cpuPercent;
}

/// One enriched sample plus the baseline the next one should be measured against.
class TelemetrySample {
  const TelemetrySample(this.metrics, this.baseline);

  final HostMetrics metrics;

  /// Null when this sample must **not** become the next baseline — see [minimumWindow].
  final TelemetryBaseline? baseline;
}

/// Below this, two probes are too close together to measure a rate from.
///
/// A manual refresh landing a fraction of a second after a scheduled poll divides a fraction of a
/// second's worth of bytes by a fraction of a second. The arithmetic is not wrong, but the answer
/// swings wildly on quantised counters — jiffies tick at 10ms — and reads as a spike in traffic
/// that never happened. The Kotlin guards only against `dt > 0` and shows those spikes.
const minimumWindow = Duration(seconds: 1);

/// Combines a freshly parsed probe with the previous one's counters.
///
/// [parsed] is what `parseMetrics` made of [raw]; [raw] is passed too because the counters live in
/// sections the parser does not keep.
///
/// With no [previous] — the first probe of a host, or the first after a restart — there is no window
/// to measure, so the rates are zero and the CPU figure falls back to whatever the host's own tools
/// reported in the probe. That is the honest answer: "not measured yet", not "idle".
TelemetrySample enrichMetrics({
  required HostMetrics parsed,
  required String raw,
  required int nowMs,
  TelemetryBaseline? previous,
}) {
  final cpuCounters = parseProcStat(raw);
  final netCounters = parseNetDev(raw);
  final diskCounters = parseDiskIo(raw);

  final elapsedMs = previous == null ? 0 : nowMs - previous.takenAtMs;
  // A negative elapsed time means the phone's clock moved backwards (an NTP correction, or the user
  // changing it). It is not a window, so it is treated as no window at all.
  final tooSoon = previous != null && elapsedMs < minimumWindow.inMilliseconds;
  final seconds = elapsedMs / 1000.0;

  final aggregateCpu = tooSoon
      ? previous.cpuPercent
      : computeCpuUsageDelta(previous?.cpu, cpuCounters, 'cpu');
  final perCore = tooSoon ? const <double>[] : computePerCoreCpuDeltas(previous?.cpu, cpuCounters);

  /// Per-second change in a cumulative counter.
  ///
  /// A result below zero means the counter reset — the host rebooted, the interface was recreated,
  /// the disk was re-attached — and the only thing that can be said about that window is nothing.
  /// Zero says "no measured throughput"; the negative number it replaces would render as a
  /// nonsensical download of several exabytes.
  int rate(int current, int start) {
    if (seconds <= 0) return 0;
    final delta = current - start;
    return delta <= 0 ? 0 : (delta / seconds).round();
  }

  final netRates = <String, (int rx, int tx)>{};
  if (!tooSoon) {
    for (final entry in netCounters.entries) {
      final start = previous?.net[entry.key];
      netRates[entry.key] = start == null
          ? (0, 0)
          : (rate(entry.value.$1, start.$1), rate(entry.value.$2, start.$2));
    }
  }

  // Linux reports per-interface counters, which is what the rates above are built from. BSD and
  // macOS have no /proc/net/dev, and their probes already carry netstat totals in the parsed
  // metrics — replacing those with an empty list would blank the network panel on every Mac.
  final interfaces = netCounters.isEmpty
      ? parsed.netInterfaces
      : [
          for (final entry in netCounters.entries)
            NetInterface(
              entry.key,
              entry.value.$1,
              entry.value.$2,
              rxPerSec: (tooSoon ? previous.netRates[entry.key]?.$1 : netRates[entry.key]?.$1) ?? 0,
              txPerSec: (tooSoon ? previous.netRates[entry.key]?.$2 : netRates[entry.key]?.$2) ?? 0,
            ),
        ];

  var readPerSec = 0;
  var writePerSec = 0;
  if (tooSoon) {
    readPerSec = previous.diskReadPerSec;
    writePerSec = previous.diskWritePerSec;
  } else if (previous != null) {
    for (final entry in diskCounters.entries) {
      final start = previous.disk[entry.key];
      if (start == null) continue;
      readPerSec += rate(entry.value.readBytes, start.readBytes);
      writePerSec += rate(entry.value.writeBytes, start.writeBytes);
    }
  }

  final metrics = parsed.copyWith(
    cpuPercent: aggregateCpu ?? parsed.cpuPercent,
    perCoreCpu: perCore.isEmpty ? parsed.perCoreCpu : perCore,
    netInterfaces: interfaces,
    diskReadPerSec: readPerSec,
    diskWritePerSec: writePerSec,
  );

  return TelemetrySample(
    metrics,
    // A sample too close to the last one must not become the baseline: doing so would leave every
    // future window measured from a moment that was itself never measurable, and a user tapping
    // refresh repeatedly would never see a rate again.
    tooSoon
        ? null
        : TelemetryBaseline(
            takenAtMs: nowMs,
            cpu: cpuCounters,
            net: netCounters,
            disk: diskCounters,
            netRates: netRates,
            diskReadPerSec: readPerSec,
            diskWritePerSec: writePerSec,
            cpuPercent: metrics.cpuPercent,
          ),
  );
}
