import 'package:intl/intl.dart';

import '../data/app_database.dart';

/// Telemetry condensation and chart labelling, ported from `ui/MonitorHistory.kt`.

const _hourMs = 3600000;

class TimedMetricPoint {
  const TimedMetricPoint(this.timestamp, this.value);

  final int timestamp;
  final double value;

  @override
  bool operator ==(Object other) =>
      other is TimedMetricPoint && other.timestamp == timestamp && other.value == value;

  @override
  int get hashCode => Object.hash(timestamp, value);
}

class HourlyMetricSeries {
  const HourlyMetricSeries({
    required this.cpu,
    required this.ram,
    required this.temperature,
  });

  final List<TimedMetricPoint> cpu;
  final List<TimedMetricPoint> ram;
  final List<TimedMetricPoint> temperature;
}

/// Condenses retained telemetry into one point per clock hour.
///
/// Temperature buckets are omitted when no sensor value was recorded, allowing the UI to hide that
/// chart without inventing zeroes — a host with no thermal sensor must not appear to be running at
/// 0°C.
HourlyMetricSeries buildHourlyMetricSeries(List<MetricHistoryRow> history) {
  final buckets = <int, List<MetricHistoryRow>>{};
  for (final row in history) {
    buckets.putIfAbsent(row.timestamp ~/ _hourMs, () => []).add(row);
  }
  final hours = buckets.keys.toList()..sort();

  double mean(Iterable<double> values) {
    var sum = 0.0;
    var count = 0;
    for (final v in values) {
      sum += v;
      count++;
    }
    return sum / count;
  }

  final cpu = <TimedMetricPoint>[];
  final ram = <TimedMetricPoint>[];
  final temperature = <TimedMetricPoint>[];

  for (final hour in hours) {
    final rows = buckets[hour]!;
    cpu.add(TimedMetricPoint(hour * _hourMs, mean(rows.map((r) => r.cpuUsage))));
    ram.add(TimedMetricPoint(hour * _hourMs, mean(rows.map((r) => r.ramUsage))));

    final readings = rows.map((r) => r.cpuTemperatureC).whereType<double>().toList();
    if (readings.isNotEmpty) {
      temperature.add(TimedMetricPoint(hour * _hourMs, mean(readings)));
    }
  }

  return HourlyMetricSeries(cpu: cpu, ram: ram, temperature: temperature);
}

/// Produces compact, real endpoint timestamps for a chart.
///
/// A date is included when the endpoints cross a local calendar day; short same-day live ranges
/// retain seconds.
///
/// The Kotlin took a `TimeZone`; Dart's [DateTime] only distinguishes local from UTC, so [utc]
/// replaces that parameter. Tests use it to stay host-independent — asserting on formatted local
/// times would otherwise depend on the machine's zone.
(String, String) chartEndpointLabels(
  List<int> timestamps, {
  String? locale,
  bool utc = false,
}) {
  if (timestamps.isEmpty) return ('—', '—');

  final first = timestamps.first;
  final last = timestamps.last;

  DateTime at(int ms) {
    final d = DateTime.fromMillisecondsSinceEpoch(ms, isUtc: utc);
    return d;
  }

  final firstDate = at(first);
  final lastDate = at(last);

  // Compared on the calendar day, not on elapsed time: 23:59 → 00:01 is only two minutes apart but
  // still needs a date to be unambiguous.
  final crossesDay = DateFormat('yyyyMMdd').format(firstDate) !=
      DateFormat('yyyyMMdd').format(lastDate);

  final pattern = crossesDay
      ? 'MMM d HH:mm'
      : (last - first < _hourMs ? 'HH:mm:ss' : 'HH:mm');

  final formatter = DateFormat(pattern, locale);
  return (formatter.format(firstDate), formatter.format(lastDate));
}
