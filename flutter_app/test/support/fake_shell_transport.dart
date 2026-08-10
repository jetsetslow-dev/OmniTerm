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

  /// Canned `exec` answers keyed by a substring of the command.
  ///
  /// Left empty by default so `exec` keeps throwing, which is what the tmux probe reads as "could
  /// not ask" — and it deliberately treats that as "assume present", so existing tests connect
  /// exactly as they did before.
  final Map<String, String> execAnswers = {};

  /// Every command passed to `exec` or `execStream`.
  final List<String> commands = [];

  /// Chunks each `execStream` replays to its `onChunk`.
  List<String> streamChunks = const [];

  @override
  Future<String> exec(SshCredentials creds, String command, {String? stdin}) async {
    commands.add(command);
    for (final entry in execAnswers.entries) {
      if (command.contains(entry.key)) return entry.value;
    }
    throw UnimplementedError('no staged answer for: $command');
  }

  @override
  Future<String> execStream(
    SshCredentials creds,
    String command, {
    String? stdin,
    SshCancellationToken? cancellation,
    required Future<void> Function(String chunk) onChunk,
  }) async {
    commands.add(command);
    for (final chunk in streamChunks) {
      await onChunk(chunk);
    }
    return streamChunks.join();
  }

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
