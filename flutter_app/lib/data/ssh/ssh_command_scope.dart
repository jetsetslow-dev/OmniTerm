import 'dart:async';

import 'ssh_transport.dart';

class SshCommandCancelled implements Exception {}

/// Owns a command's deadline, including time spent queued or acquiring its channel.
/// Unlike Future.timeout, cancellation prevents later stages from starting and disposes resources
/// that arrive after the caller has stopped waiting. It never retries a dispatched command.
class SshCommandScope {
  SshCommandScope(Duration timeout, {SshCancellationToken? cancellation})
    : _external = cancellation {
    _timer = Timer(timeout, () {
      _timedOut = true;
      _cancel();
    });
    _subscription = cancellation?.onCancel.listen((_) => _cancel());
    if (cancellation?.isCancelled ?? false) _cancel();
  }

  final SshCancellationToken? _external;
  final _stopped = Completer<void>();
  late final Timer _timer;
  StreamSubscription<void>? _subscription;
  bool _timedOut = false;
  bool _cancelled = false;

  bool get isCancelled => _cancelled || (_external?.isCancelled ?? false);

  Object get _error => _timedOut ? TimeoutException('command timed out') : SshCommandCancelled();

  void _cancel() {
    _cancelled = true;
    if (!_stopped.isCompleted) _stopped.complete();
  }

  void check() {
    if (isCancelled) throw _error;
  }

  Future<T> wait<T>(Future<T> Function() start, {void Function(T)? onLateResult}) {
    check();
    final result = Completer<T>();
    final pending = Future<T>.sync(start);
    unawaited(
      _stopped.future.then((_) {
        if (!result.isCompleted) result.completeError(_error);
      }),
    );
    unawaited(
      pending.then(
        (value) {
          if (result.isCompleted || isCancelled) {
            onLateResult?.call(value);
            if (!result.isCompleted) result.completeError(_error);
          } else {
            result.complete(value);
          }
        },
        onError: (Object error, StackTrace stack) {
          // Always consume late errors, even after cancellation has already returned to the UI.
          if (!result.isCompleted) result.completeError(isCancelled ? _error : error, stack);
        },
      ),
    );
    return result.future;
  }

  Future<void> dispose() async {
    _timer.cancel();
    await _subscription?.cancel();
    // Release callbacks retained by completed waits without leaving a pending signal behind.
    if (!_stopped.isCompleted) _stopped.complete();
  }
}
