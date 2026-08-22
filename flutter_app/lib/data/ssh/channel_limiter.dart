import 'dart:async';
import 'dart:collection';

/// Caps how many channels this app opens at once on a single SSH connection.
///
/// SSH multiplexes sessions over one connection, and the server decides how many it will grant:
/// OpenSSH's `MaxSessions` defaults to **10**, and NAS firmware often ships lower. Exceeding it does
/// not queue — the server refuses the channel, and dartssh2 raises
/// `SSHChannelOpenError(2: open failed)`.
///
/// The port hit this for real. `InfraViewModel.load` issues six `exec` calls through one
/// `Future.wait` — deliberately, because serialising them multiplies the round-trip latency by six
/// on the screen a user opens to check something quickly. Six is under ten on its own, but the
/// telemetry poller and the host-status probe share the same pooled connection, and the server
/// counts the total. The device host suite failed exactly there.
///
/// So the fan-out is kept and bounded instead: callers past the limit wait for a slot rather than
/// being refused by the server. That preserves the latency argument — six probes still overlap, just
/// [maxConcurrent] at a time — and removes the failure mode entirely rather than making it rarer.
class ChannelLimiter {
  ChannelLimiter({this.maxConcurrent = 4});

  /// Deliberately well under OpenSSH's default of 10.
  ///
  /// This limiter only governs `exec` and `execStream`. Interactive shells, SFTP subsystems and
  /// tunnels open channels on the same connection without passing through here, so the budget has
  /// to leave room for them — a limit of 8 would be "correct" against the default and would still
  /// fail on a host with a shell open and `MaxSessions 10`.
  final int maxConcurrent;

  final Map<String, int> _inFlight = {};
  final Map<String, Queue<Completer<void>>> _waiting = {};

  /// Runs [action] once a slot on [key] is free.
  Future<T> run<T>(String key, Future<T> Function() action) async {
    await _take(key);
    try {
      return await action();
    } finally {
      _release(key);
    }
  }

  Future<void> _take(String key) async {
    final current = _inFlight[key] ?? 0;
    if (current < maxConcurrent) {
      _inFlight[key] = current + 1;
      return;
    }
    final waiter = Completer<void>();
    (_waiting[key] ??= Queue<Completer<void>>()).add(waiter);
    return waiter.future;
  }

  void _release(String key) {
    final queue = _waiting[key];
    if (queue != null && queue.isNotEmpty) {
      // Hand the slot straight to the next waiter rather than decrementing and letting it race:
      // the count never dips, so a burst cannot slip past the limit between the two operations.
      queue.removeFirst().complete();
      if (queue.isEmpty) _waiting.remove(key);
      return;
    }
    final current = (_inFlight[key] ?? 1) - 1;
    if (current <= 0) {
      _inFlight.remove(key);
    } else {
      _inFlight[key] = current;
    }
  }

  /// How many slots are in use for [key], for tests.
  int inFlightFor(String key) => _inFlight[key] ?? 0;
}
