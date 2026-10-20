import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:omniterm/data/ssh/ssh_host_key_trust.dart';
import 'package:omniterm/data/ssh/ssh_setup_deadline.dart';

void main() {
  SshSetupDeadline deadline(WidgetTester tester) => SshSetupDeadline(
    phase: 'Fixture SSH authentication',
    stopwatch: tester.binding.clock.stopwatch(),
  );

  testWidgets('silent setup expires and a late forwarding channel is retired once', (tester) async {
    final budget = deadline(tester);
    final pending = Completer<Object>();
    final lateChannel = Object();
    final retired = <Object>[];
    final outcome = _Outcome(budget.run(() => pending.future, onLateResult: retired.add));
    await tester.pump(const Duration(seconds: 14));
    expect(outcome.error, isNull);
    await tester.pump(const Duration(seconds: 1));
    expect(outcome.error, isA<TimeoutException>());
    expect('${outcome.error}', contains('Fixture SSH authentication timed out'));
    pending.complete(lateChannel);
    await tester.pump();
    expect(retired, [same(lateChannel)]);
  });

  testWidgets('approval pauses only the unspent network budget', (tester) async {
    final budget = deadline(tester);
    final authentication = Completer<void>();
    final outcome = _Outcome(budget.run(() => authentication.future));
    await tester.pump(const Duration(seconds: 4));
    final answer = Completer<bool>();
    final approval = _Outcome(budget.awaitApproval(() => answer.future));
    await tester.pump(const Duration(seconds: 90));
    expect(outcome.error, isNull);
    expect(outcome.completed, isFalse);
    answer.complete(true);
    await tester.pump();
    expect(approval.value, isTrue);
    await tester.pump(const Duration(seconds: 10));
    expect(outcome.completed, isFalse);
    await tester.pump(const Duration(seconds: 1));
    expect(outcome.error, isA<TimeoutException>());
    // The late SSH failure must be consumed, not escape as an unhandled async exception.
    authentication.completeError(StateError('peer finally closed'));
    await tester.pump();
  });

  testWidgets('successful setup stops its timer and permits later rekey verification', (
    tester,
  ) async {
    final budget = deadline(tester);
    final outcome = _Outcome(budget.run(() async => 'connected'));
    await tester.pump();
    expect(outcome.value, 'connected');
    await tester.pump(const Duration(minutes: 5));
    expect(outcome.error, isNull);
    expect(await budget.awaitApproval(() async => true), isTrue);
  });

  testWidgets('trust-store reads stay bounded and cannot open a prompt after expiration', (
    tester,
  ) async {
    final budget = deadline(tester);
    final store = _DelayedStore()..readGate = Completer<void>();
    final trust = SshHostKeyTrust(store);
    var prompts = 0;
    trust.registerApprovalHandler(Object(), (request) {
      prompts++;
      request.completer.complete(true);
    });
    final outcome = _Outcome(budget.run(() => _check(trust, budget)));
    await tester.pump(const Duration(seconds: 15));
    expect(outcome.error, isA<TimeoutException>());
    store.readGate!.complete();
    await tester.pump();
    expect(prompts, 0);
    expect(await store.readAll(), isEmpty);
  });

  testWidgets('the real trust layer allows approval beyond the network deadline', (tester) async {
    final budget = deadline(tester);
    final store = InMemoryHostKeyStore();
    final trust = SshHostKeyTrust(store);
    HostKeyApprovalRequest? request;
    trust.registerApprovalHandler(Object(), (value) => request = value);
    final outcome = _Outcome(budget.run(() => _check(trust, budget)));
    await tester.pump();
    expect(request, isNotNull);
    await tester.pump(const Duration(seconds: 119));
    expect(outcome.completed, isFalse);
    request!.completer.complete(true);
    await tester.pump();
    expect(outcome.value, HostKeyVerdict.ok);
    expect(await store.read('fixture|ssh-ed25519'), 'SHA256:fixture');
  });

  testWidgets('approval still fails closed at its own 120-second limit', (tester) async {
    final budget = deadline(tester);
    final store = InMemoryHostKeyStore();
    final trust = SshHostKeyTrust(store);
    HostKeyApprovalRequest? request;
    trust.registerApprovalHandler(Object(), (value) => request = value);
    final outcome = _Outcome(budget.run(() => _check(trust, budget)));
    await tester.pump();
    await tester.pump(const Duration(seconds: 120));
    expect(outcome.value, HostKeyVerdict.notIncluded);
    expect(request!.completer.isCompleted, isTrue);
    expect(await store.readAll(), isEmpty);
  });

  testWidgets('trust-store persistence after approval is not exempt from the deadline', (
    tester,
  ) async {
    final budget = deadline(tester);
    final store = _DelayedStore()..writeGate = Completer<void>();
    final trust = SshHostKeyTrust(store);
    trust.registerApprovalHandler(Object(), (request) => request.completer.complete(true));
    final outcome = _Outcome(budget.run(() => _check(trust, budget)));
    await tester.pump();
    await tester.pump(const Duration(seconds: 15));
    expect(outcome.error, isA<TimeoutException>());
    store.writeGate!.complete();
    await tester.pump();
  });

  testWidgets('connection failure during approval prevents a late pin or a new prompt', (
    tester,
  ) async {
    final budget = deadline(tester);
    final failure = Completer<HostKeyVerdict>();
    final store = InMemoryHostKeyStore();
    final trust = SshHostKeyTrust(store);
    HostKeyApprovalRequest? request;
    trust.registerApprovalHandler(Object(), (value) => request = value);
    final verification = _Outcome(_check(trust, budget));
    final outcome = _Outcome(budget.run(() => failure.future));
    await tester.pump();
    failure.completeError(StateError('connection closed'));
    await tester.pump();
    expect(outcome.error, isA<StateError>());
    request!.completer.complete(true);
    await tester.pump();
    expect(verification.value, HostKeyVerdict.notIncluded);
    expect(await store.readAll(), isEmpty);
    expect(await budget.awaitApproval(() => throw StateError('must not prompt')), isFalse);
  });
}

Future<HostKeyVerdict> _check(SshHostKeyTrust trust, SshSetupDeadline budget) => trust.check(
  host: 'fixture',
  port: 22,
  keyType: 'ssh-ed25519',
  fingerprint: 'SHA256:fixture',
  waitForApproval: budget.awaitApproval,
);

class _Outcome<T> {
  _Outcome(Future<T> pending) {
    unawaited(
      pending.then<void>(
        (result) {
          value = result;
          completed = true;
        },
        onError: (Object failure, StackTrace _) {
          error = failure;
          completed = true;
        },
      ),
    );
  }

  T? value;
  Object? error;
  bool completed = false;
}

class _DelayedStore extends InMemoryHostKeyStore {
  Completer<void>? readGate;
  Completer<void>? writeGate;

  @override
  Future<Map<String, String>> readAll() async {
    await readGate?.future;
    return super.readAll();
  }

  @override
  Future<void> write(String key, String value) async {
    await writeGate?.future;
    await super.write(key, value);
  }
}
