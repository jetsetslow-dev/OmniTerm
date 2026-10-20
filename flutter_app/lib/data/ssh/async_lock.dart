import 'dart:async';

/// A mutual-exclusion lock for asynchronous critical sections.
///
/// Most Kotlin `@Synchronized` methods need **no** Dart equivalent: an isolate is single-threaded,
/// so a purely synchronous method cannot interleave. A lock is required only where the critical
/// section contains an `await` — at that point another task genuinely can run between the read and
/// the write. Both users here are of that kind: pinning a host key and building a pooled connection
/// each await I/O partway through.
class AsyncLock {
  Future<void> _tail = Future.value();

  Future<T> synchronized<T>(Future<T> Function() action) {
    final completer = Completer<T>();
    final previous = _tail;
    // The chain must not break on failure, or one thrown action would deadlock every later waiter.
    _tail = completer.future.then((_) {}, onError: (_) {});
    previous.whenComplete(() async {
      try {
        completer.complete(await action());
      } catch (e, s) {
        completer.completeError(e, s);
      }
    });
    return completer.future;
  }
}
