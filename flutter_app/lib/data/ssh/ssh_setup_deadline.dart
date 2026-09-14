import 'dart:async';

/// A single SSH setup stage's network budget, excluding only interactive host-key approval.
/// TCP's connect timeout does not cover a silent SSH peer, authentication, or bastion forwarding.
/// No stage is retried; the caller must close its owned connection when [run] fails.
class SshSetupDeadline {
  SshSetupDeadline({
    required this.phase,
    this.timeout = const Duration(seconds: 15),
    Stopwatch? stopwatch,
  }) : _clock = stopwatch ?? Stopwatch();

  final String phase;
  final Duration timeout;
  final Stopwatch _clock;
  final _expiredSignal = Completer<void>();
  Timer? _timer;
  bool _started = false;
  bool _settled = false;
  bool _expired = false;
  bool _succeeded = false;

  TimeoutException get _error =>
      TimeoutException('$phase timed out. Check the connection and retry.', timeout);

  void _arm() {
    _timer = Timer(timeout - _clock.elapsed, () {
      _expired = true;
      if (!_expiredSignal.isCompleted) _expiredSignal.complete();
    });
  }

  Future<T> run<T>(Future<T> Function() start, {void Function(T)? onLateResult}) async {
    if (_started) throw StateError('An SSH setup deadline can only run once');
    _started = true;
    _clock.start();
    _arm();
    final pending = Future<T>.sync(start);
    // A timed-out forwarding request may still deliver a channel. Retire that late resource,
    // and always consume late failures instead of reporting an unhandled asynchronous error.
    unawaited(
      pending.then<void>((value) {
        if (_expired) onLateResult?.call(value);
      }, onError: (Object _, StackTrace _) {}),
    );
    try {
      final result = await Future.any<T>([
        pending,
        _expiredSignal.future.then<T>((_) => throw _error),
      ]);
      if (_expired) throw _error;
      _succeeded = true;
      return result;
    } finally {
      _settled = true;
      _timer?.cancel();
      _clock.stop();
      // Release the losing race's callbacks even when setup completed normally. Future.any has
      // already installed its error handler, so this never creates a late unhandled timeout.
      if (!_expiredSignal.isCompleted) _expiredSignal.complete();
    }
  }

  /// Called around the actual user decision, not around trust-store reads or writes. The trust
  /// layer retains its own 120-second approval deadline. A failed/retired connection may neither
  /// open a late prompt nor persist an answer to one that was already visible.
  Future<bool> awaitApproval(Future<bool> Function() request) async {
    if (_settled) return _succeeded ? request() : false;
    if (_expired) return false;
    _clock.stop();
    _timer?.cancel();
    try {
      final approved = await request();
      return approved && !_expired && (!_settled || _succeeded);
    } finally {
      if (!_settled && !_expired) {
        _clock.start();
        _arm();
      }
    }
  }
}
