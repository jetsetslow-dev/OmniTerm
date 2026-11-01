import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:omniterm/data/ssh/channel_limiter.dart';
import 'package:omniterm/data/ssh/ssh_command_scope.dart';
import 'package:omniterm/data/ssh/ssh_transport.dart';

void main() {
  test('pre-cancellation prevents even the first stage', () async {
    final token = SshCancellationToken()..cancel();
    final scope = SshCommandScope(const Duration(seconds: 5), cancellation: token);
    var started = false;
    try {
      expect(() => scope.wait(() async => started = true), throwsA(isA<SshCommandCancelled>()));
      expect(started, isFalse);
    } finally {
      await scope.dispose();
      await token.close();
    }
  });

  for (final failLate in [false, true]) {
    test('cancelled wait consumes a late ${failLate ? 'error' : 'resource'}', () async {
      final token = SshCancellationToken();
      final scope = SshCommandScope(const Duration(seconds: 5), cancellation: token);
      final resource = Completer<int>();
      var disposed = 0;
      try {
        final stopped = expectLater(
          scope.wait(() => resource.future, onLateResult: (value) => disposed += value),
          throwsA(isA<SshCommandCancelled>()),
        );
        token.cancel();
        await stopped.timeout(const Duration(seconds: 1));
        await scope.dispose();
        if (failLate) {
          resource.completeError(StateError('late setup failure'));
        } else {
          resource.complete(1);
        }
        await Future<void>.delayed(Duration.zero);
        expect(disposed, failLate ? 0 : 1);
      } finally {
        await scope.dispose();
        await token.close();
      }
    });
  }

  for (final timeout in [false, true]) {
    test(
      '${timeout ? 'timeout' : 'cancellation'} removes queued work without running it',
      () async {
        final limiter = ChannelLimiter(maxConcurrent: 1);
        final gate = Completer<void>();
        final first = limiter.run('host', () => gate.future);
        final token = SshCancellationToken();
        final scope = SshCommandScope(
          timeout ? const Duration(milliseconds: 30) : const Duration(seconds: 5),
          cancellation: token,
        );
        var cancelledRan = false;
        final order = <int>[];
        try {
          final stopped = expectLater(
            limiter.run('host', () async => cancelledRan = true, scope: scope),
            throwsA(timeout ? isA<TimeoutException>() : isA<SshCommandCancelled>()),
          );
          final second = limiter.run('host', () async => order.add(2));
          final third = limiter.run('host', () async => order.add(3));
          if (!timeout) token.cancel();
          await stopped.timeout(const Duration(seconds: 1));
          expect(limiter.inFlightFor('host'), 1);
          gate.complete();
          await Future.wait([first, second, third]);
          expect(cancelledRan, isFalse);
          expect(order, [2, 3]);
          expect(limiter.inFlightFor('host'), 0);
        } finally {
          if (!gate.isCompleted) gate.complete();
          await first;
          await scope.dispose();
          await token.close();
        }
      },
    );
  }

  test('cancellation racing slot handoff never leaks or double releases the slot', () async {
    for (final cancelFirst in [false, true]) {
      final limiter = ChannelLimiter(maxConcurrent: 1);
      final token = SshCancellationToken();
      final scope = SshCommandScope(const Duration(seconds: 5), cancellation: token);
      final gate = Completer<void>();
      final first = limiter.run('host', () async {
        await gate.future;
        if (cancelFirst) token.cancel();
      });
      var ran = false;
      final stopped = expectLater(
        limiter.run('host', () async => ran = true, scope: scope),
        throwsA(isA<SshCommandCancelled>()),
      );
      try {
        await Future<void>.delayed(Duration.zero);
        gate.complete();
        await first;
        if (!cancelFirst) token.cancel();
        await stopped;
        expect(ran, isFalse);
        expect(limiter.inFlightFor('host'), 0);
        await limiter.run('host', () async {});
        expect(limiter.inFlightFor('host'), 0);
      } finally {
        await scope.dispose();
        await token.close();
      }
    }
  });

  test('successful stages retain their result and release the deadline', () async {
    final scope = SshCommandScope(const Duration(milliseconds: 30));
    var disposed = false;
    expect(await scope.wait(() async => 42, onLateResult: (_) => disposed = true), 42);
    await scope.dispose();
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(scope.isCancelled, isFalse);
    expect(disposed, isFalse);
  });
}
