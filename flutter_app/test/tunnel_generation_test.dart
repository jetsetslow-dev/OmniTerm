import 'package:flutter_test/flutter_test.dart';
import 'package:omniterm/data/ssh/tunnel_generation.dart';

/// `stop()` deliberately does not take the per-tunnel lock, so that stopping never queues behind a
/// start hung dialling an unreachable host. This token is the whole reason that is safe, so it is
/// tested around the ways a tunnel could survive its own stop.
void main() {
  test('a start with an untouched generation publishes', () {
    final gen = TunnelGeneration();
    final expected = gen.snapshot();
    var published = false;
    var rolledBack = false;

    final ok = gen.publishIfCurrent(
      expected: expected,
      publish: () => published = true,
      rollback: () => rolledBack = true,
    );

    expect(ok, isTrue);
    expect(published, isTrue);
    expect(rolledBack, isFalse);
  });

  test('a stop landing mid-start prevents publication', () {
    // The real sequence: start() snapshots, awaits its connect, and stop() runs in between.
    final gen = TunnelGeneration();
    final expected = gen.snapshot();
    gen.invalidate();

    var published = false;
    final ok = gen.publishIfCurrent(
      expected: expected,
      publish: () => published = true,
      rollback: () {},
    );

    expect(ok, isFalse);
    expect(
      published,
      isFalse,
      reason: 'a tunnel must not be left alive after stop() returned to its caller',
    );
  });

  test('rollback runs when a stop lands inside the publish window', () {
    // Cannot happen today on a single isolate, since publish is synchronous — but the guard exists
    // so that adding an await inside a publish callback cannot silently reintroduce the leak.
    final gen = TunnelGeneration();
    final expected = gen.snapshot();
    var rolledBack = false;

    final ok = gen.publishIfCurrent(
      expected: expected,
      publish: gen.invalidate,
      rollback: () => rolledBack = true,
    );

    expect(ok, isFalse);
    expect(rolledBack, isTrue);
  });

  test('each invalidate supersedes every earlier in-flight start', () {
    final gen = TunnelGeneration();
    final first = gen.snapshot();
    gen.invalidate();
    final second = gen.snapshot();

    expect(
      gen.publishIfCurrent(expected: first, publish: () {}, rollback: () {}),
      isFalse,
      reason: 'the superseded start must lose',
    );
    expect(
      gen.publishIfCurrent(expected: second, publish: () {}, rollback: () {}),
      isTrue,
      reason: 'the newest start still owns the tunnel',
    );
  });

  test('generations advance monotonically', () {
    final gen = TunnelGeneration();
    expect(gen.snapshot(), 0);
    expect(gen.invalidate(), 1);
    expect(gen.invalidate(), 2);
    expect(gen.snapshot(), 2);
  });

  test('repeated stops stay safe and keep superseding', () {
    final gen = TunnelGeneration();
    final expected = gen.snapshot();
    gen
      ..invalidate()
      ..invalidate()
      ..invalidate();
    expect(gen.publishIfCurrent(expected: expected, publish: () {}, rollback: () {}), isFalse);
  });
}
