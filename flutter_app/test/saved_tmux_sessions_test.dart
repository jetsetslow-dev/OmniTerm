import 'package:flutter_test/flutter_test.dart';
import 'package:omniterm/domain/saved_tmux_sessions.dart';

/// As the `endRemoteTmux` cases in Kotlin's `SavedTmuxSessionsTest`.
void main() {
  test('only a confirmed absence counts as ended', () async {
    expect(
      await endRemoteTmux(kill: () async => '', stillExists: () async => false),
      isA<TmuxEnded>(),
    );
    expect(
      await endRemoteTmux(kill: () async => '', stillExists: () async => true),
      isA<TmuxNotConfirmed>(),
    );
    expect(
      await endRemoteTmux(kill: () async => '', stillExists: () async => null),
      isA<TmuxNotConfirmed>(),
      reason: 'an answer tmux could not give is not proof the session is gone',
    );
  });

  test('an unreachable server says why and is never asked whether the session is gone', () async {
    var asked = false;
    final result = await endRemoteTmux(
      kill: () async => 'SSH Error: connection refused\n',
      stillExists: () async {
        asked = true;
        return false;
      },
    );
    expect((result as TmuxUnreachable).reason, 'SSH Error: connection refused');
    expect(asked, isFalse);
  });
}
