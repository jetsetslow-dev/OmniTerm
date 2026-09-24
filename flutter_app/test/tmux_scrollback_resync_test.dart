import 'package:flutter_test/flutter_test.dart';
import 'package:omniterm/data/remote_commands.dart';

void main() {
  group('the capture command', () {
    test('is guarded on the alternate screen, and produces nothing while a TUI owns the pane', () {
      // The guard is the whole reason this is a shell conditional rather than a bare `capture-pane`.
      // While a full-screen TUI owns the pane, `capture-pane` returns the TUI's frames instead of
      // the primary screen's history (verified against tmux 3.3a), and adopting those would replace
      // real scrollback with `vim` repaints. Kotlin guards it identically at
      // `data/RemoteParsers.kt:280`.
      final command = tmuxCaptureHistoryCommand('omniterm-work', 5000);

      expect(command, contains("display-message -p -t omniterm-work '#{alternate_on}'"));
      expect(command, contains('= 1 ]; then :;'), reason: 'alternate on must produce no output');
      expect(command, contains('capture-pane -p -e -J -S -5000 -E -1 -t omniterm-work'));
    });

    test('never fails the exec, whatever tmux says', () {
      // The caller treats an error string as "leave the dirty flag armed". A non-zero exit would
      // surface as an SSH error and be indistinguishable from a dead connection.
      expect(tmuxCaptureHistoryCommand('x', 5000), endsWith('|| true'));
    });

    test('clamps the depth to the band Kotlin uses', () {
      // Below 1,000 the round trip costs more than the history is worth; above 50,000 the transfer
      // costs more than the scrollback can even hold.
      expect(tmuxCaptureHistoryCommand('x', 10), contains('-S -1000'));
      expect(tmuxCaptureHistoryCommand('x', 999999), contains('-S -50000'));
    });

    test('a session name is reduced to what is safe to interpolate', () {
      // The name reaches the remote inside a command string. Anything outside the safe set is
      // dropped rather than escaped, and a name that reduces to nothing falls back rather than
      // producing a bare `-t ` and a syntax error.
      expect(tmuxSafeSessionName('omniterm-1'), 'omniterm-1');
      expect(tmuxSafeSessionName(r'evil; rm -rf /'), 'evilrm-rf');
      expect(tmuxSafeSessionName(';;;'), 'omniterm');
      expect(tmuxCaptureHistoryCommand(r'a`b$c', 5000), isNot(contains(r'$c')));
    });
  });
}
