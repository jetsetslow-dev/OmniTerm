/// Overall progress across the transfers currently running.
///
/// Ported from `TransferAggregate` and `transferAggregate` in `ui/AppViewModel.kt:498`, `:9874`.
///
/// Flutter showed a progress bar per file and nothing above them, which answers "is this file
/// moving?" but not "how long until my 4 GB of photos are across" — the only question worth asking
/// during a batch.
library;

/// One running transfer's contribution to the aggregate.
class TransferProgress {
  const TransferProgress({
    required this.bytesTransferred,
    required this.totalBytes,
    required this.speedKbps,
  });

  final int bytesTransferred;

  /// Zero when the size is not known in advance.
  final int totalBytes;

  final double speedKbps;
}

class TransferAggregate {
  const TransferAggregate({
    required this.activeFiles,
    required this.bytesTransferred,
    required this.totalBytes,
    required this.speedKbps,
  });

  final int activeFiles;
  final int bytesTransferred;
  final int totalBytes;
  final double speedKbps;

  /// False when nothing running has declared a size, so the bar shows motion rather than a figure.
  bool get hasKnownTotal => totalBytes > 0;

  double get fraction =>
      totalBytes > 0 ? (bytesTransferred / totalBytes).clamp(0.0, 1.0) : 0.0;

  /// Seconds remaining, or -1 when it cannot be estimated.
  ///
  /// Negative rather than null to match Kotlin, and because "unknown" and "nearly done" must not
  /// render the same way — a `0` here would read as "finishing now".
  int get etaSeconds {
    final remaining = totalBytes - bytesTransferred;
    if (speedKbps <= 0 || remaining <= 0) return -1;
    return (remaining / (speedKbps * 1024)).round();
  }
}

/// Combines the running transfers, or null when none are.
///
/// **Only sized rows contribute to the total.** A transfer whose size the server never declared
/// would otherwise drag the aggregate to 0% and make a nearly finished batch look untouched.
TransferAggregate? aggregateTransfers(Iterable<TransferProgress> running) {
  final list = running.toList();
  if (list.isEmpty) return null;
  var done = 0;
  var total = 0;
  var speed = 0.0;
  for (final t in list) {
    done += t.bytesTransferred < 0 ? 0 : t.bytesTransferred;
    if (t.totalBytes > 0) total += t.totalBytes;
    speed += t.speedKbps;
  }
  return TransferAggregate(
    activeFiles: list.length,
    bytesTransferred: done,
    totalBytes: total,
    speedKbps: speed,
  );
}

/// A short human duration for an ETA, e.g. `45s`, `2m`, `1h 5m`.
String formatEta(int seconds) {
  if (seconds < 60) return '${seconds}s';
  if (seconds < 3600) return '${seconds ~/ 60}m';
  final hours = seconds ~/ 3600;
  final minutes = (seconds % 3600) ~/ 60;
  return minutes == 0 ? '${hours}h' : '${hours}h ${minutes}m';
}

/// Transfer speed for display, or "" when nothing is moving yet.
String formatSpeed(double speedKbps) {
  if (speedKbps >= 1024) return '${(speedKbps / 1024).toStringAsFixed(1)} MB/s';
  if (speedKbps > 0) return '${speedKbps.toStringAsFixed(0)} KB/s';
  return '';
}
