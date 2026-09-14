import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:omniterm/data/ssh/channel_limiter.dart';

void main() {
  test('a burst never exceeds the limit, and everything still runs', () async {
    // Infra fires six probes at once. The server counts channels, and OpenSSH grants ten by
    // default across *everything* on the connection — so six from one screen plus the poller and a
    // status probe is how `SSHChannelOpenError(2: open failed)` happened on the device suite.
    final limiter = ChannelLimiter(maxConcurrent: 4);
    final gates = <Completer<void>>[];
    var running = 0;
    var peak = 0;
    var completed = 0;

    final calls = [
      for (var i = 0; i < 6; i++)
        limiter.run('host', () async {
          running++;
          if (running > peak) peak = running;
          final gate = Completer<void>();
          gates.add(gate);
          await gate.future;
          running--;
          completed++;
        }),
    ];

    await Future<void>.delayed(Duration.zero);
    expect(peak, 4, reason: 'the fifth and sixth wait for a slot rather than being refused');
    expect(gates, hasLength(4));

    // Releasing one admits exactly one more, never two.
    gates[0].complete();
    await Future<void>.delayed(Duration.zero);
    expect(peak, 4);
    expect(gates, hasLength(5));

    for (var i = 1; i < gates.length; i++) {
      gates[i].complete();
      await Future<void>.delayed(Duration.zero);
    }
    while (gates.length < 6) {
      await Future<void>.delayed(Duration.zero);
    }
    for (final gate in gates) {
      if (!gate.isCompleted) gate.complete();
    }
    await Future.wait(calls);

    expect(completed, 6, reason: 'bounding must not drop work');
    expect(peak, 4);
    expect(limiter.inFlightFor('host'), 0, reason: 'every slot is handed back');
  });

  test('the default leaves room under OpenSSH MaxSessions', () {
    // Every other test here passes an explicit limit, so none of them pins the number that actually
    // ships — raising the default to 99 left the whole file green. The default is the entire point:
    // it has to sit under `MaxSessions 10` *and* leave room for the shell, SFTP and tunnel channels
    // that open on the same connection without passing through this limiter.
    expect(ChannelLimiter().maxConcurrent, 4);
    expect(ChannelLimiter().maxConcurrent, lessThan(10));
  });

  test('different hosts do not share a budget', () async {
    // The limit models one server's MaxSessions, not this app's appetite.
    final limiter = ChannelLimiter(maxConcurrent: 1);
    final first = Completer<void>();
    final second = Completer<void>();
    var startedB = false;

    final a = limiter.run('host-a', () => first.future);
    final b = limiter.run('host-b', () async {
      startedB = true;
      await second.future;
    });

    await Future<void>.delayed(Duration.zero);
    expect(startedB, isTrue, reason: 'host-b is a different connection with its own limit');

    first.complete();
    second.complete();
    await Future.wait([a, b]);
    expect(limiter.inFlightFor('host-a'), 0);
    expect(limiter.inFlightFor('host-b'), 0);
  });

  test('a slot is released even when the work throws', () async {
    // A failed exec must not permanently consume a slot, or a few errors would deadlock the host.
    final limiter = ChannelLimiter(maxConcurrent: 1);

    await expectLater(limiter.run('host', () async => throw StateError('boom')), throwsStateError);
    expect(limiter.inFlightFor('host'), 0);

    var ran = false;
    await limiter.run('host', () async => ran = true);
    expect(ran, isTrue, reason: 'the next caller still gets in');
  });
}
