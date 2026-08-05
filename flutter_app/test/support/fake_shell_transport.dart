import 'dart:async';

import 'package:omniterm/data/ssh/ssh_transport.dart';

import 'fake_terminal_session.dart';

/// An [SshTransport] that only knows how to open shells.
class FakeShellTransport implements SshTransport {
  FakeShellTransport({this.failure, this.phases = const []});

  /// When set, `openShell` throws it instead of connecting.
  Object? failure;

  /// Progress strings replayed to `onPhaseChange`, so a test can watch the connecting view.
  final List<String> phases;

  /// Every shell opened, newest last.
  final List<FakeTerminalSession> opened = [];

  final List<(int, int)> openSizes = [];

  /// The credentials each shell was opened with, so a test can check *which* host was dialled.
  final List<SshCredentials> openedWith = [];

  /// Completes each `openShell` only when released, so the connecting state can be observed.
  Completer<void>? gate;

  @override
  Future<TerminalSession> openShell(
    SshCredentials creds,
    int cols,
    int rows, {
    void Function(String phase)? onPhaseChange,
  }) async {
    openSizes.add((cols, rows));
    openedWith.add(creds);
    for (final phase in phases) {
      onPhaseChange?.call(phase);
    }
    if (gate != null) await gate!.future;
    if (failure != null) throw failure!;
    final session = FakeTerminalSession();
    opened.add(session);
    return session;
  }

  Future<void> dispose() async {
    for (final session in opened) {
      await session.dispose();
    }
  }

  @override
  noSuchMethod(Invocation invocation) => throw UnimplementedError();
}
