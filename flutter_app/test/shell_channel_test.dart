import 'dart:async';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omniterm/data/ssh/shell_channel.dart';

void main() {
  test('a ready channel is returned without closing its client', () async {
    final session = _Session();
    final client = _Client((_) async => session);
    expect(await openInteractiveShellChannel(client, const SSHPtyConfig()), same(session));
    expect(client.closeCount, 0);
    expect(session.closeCount, 0);
    expect(client.environments, [
      {'COLORTERM': 'truecolor'},
    ]);
  });

  test('explicit environment refusal falls back without colour metadata', () async {
    final session = _Session();
    final client = _Client((environment) async {
      if (environment != null) throw SSHChannelRequestError('environment refused');
      return session;
    });
    expect(await openInteractiveShellChannel(client, const SSHPtyConfig()), same(session));
    expect(client.environments, [
      {'COLORTERM': 'truecolor'},
      null,
    ]);
    expect(client.closeCount, 0);
  });

  for (final lateFailure in [false, true]) {
    test(
      'late ${lateFailure ? 'rejection cannot retry' : 'success is closed'} after timeout',
      () async {
        final pending = Completer<SSHSession>();
        final client = _Client((_) => pending.future);
        await expectLater(
          openInteractiveShellChannel(
            client,
            const SSHPtyConfig(),
            timeout: const Duration(milliseconds: 20),
          ),
          throwsA(isA<TimeoutException>()),
        );
        final session = _Session();
        if (lateFailure) {
          pending.completeError(SSHChannelRequestError('late rejection'));
        } else {
          pending.complete(session);
        }
        await Future<void>.delayed(Duration.zero);
        expect(client.closeCount, 1);
        expect(client.environments, hasLength(1));
        expect(session.closeCount, lateFailure ? 0 : 1);
      },
    );
  }

  test('fallback negotiation also has a deadline', () async {
    final pending = Completer<SSHSession>();
    final client = _Client((environment) {
      if (environment != null) throw SSHChannelRequestError('environment refused');
      return pending.future;
    });
    await expectLater(
      openInteractiveShellChannel(
        client,
        const SSHPtyConfig(),
        timeout: const Duration(milliseconds: 20),
      ),
      throwsA(isA<TimeoutException>()),
    );
    expect(client.closeCount, 1);
    expect(client.environments, hasLength(2));
    pending.completeError(SSHChannelRequestError('closed'));
    await Future<void>.delayed(Duration.zero);
  });

  test('a stalled channel closes its owned client and reports a bounded failure', () async {
    final pending = Completer<SSHSession>();
    final client = _Client((_) => pending.future);
    final opening = openInteractiveShellChannel(
      client,
      const SSHPtyConfig(),
      timeout: const Duration(milliseconds: 20),
    );
    try {
      await expectLater(
        opening.timeout(const Duration(milliseconds: 200)),
        throwsA(isA<TimeoutException>()),
      );
      expect(client.closeCount, 1, reason: 'A deadline must retire the stalled SSH connection');
      expect(client.environments, hasLength(1));
    } finally {
      pending.complete(_Session());
      await opening.catchError((Object _) => _Session());
    }
  });
}

class _Client implements SSHClient {
  _Client(this.open);
  final Future<SSHSession> Function(Map<String, String>?) open;
  final environments = <Map<String, String>?>[];
  int closeCount = 0;

  @override
  Future<SSHSession> shell({
    SSHPtyConfig? pty = const SSHPtyConfig(),
    SSHX11Config? x11,
    Map<String, String>? environment,
  }) {
    environments.add(environment);
    return open(environment);
  }

  @override
  void close() => closeCount++;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Session implements SSHSession {
  int closeCount = 0;
  @override
  void close() => closeCount++;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
