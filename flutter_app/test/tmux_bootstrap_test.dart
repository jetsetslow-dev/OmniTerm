import 'package:flutter_test/flutter_test.dart';
import 'package:omniterm/data/term/tmux_bootstrap.dart';

void main() {
  group('tmuxSafeName', () {
    test('ordinary names pass through', () {
      expect(tmuxSafeName('omniterm-nas-1'), 'omniterm-nas-1');
      expect(tmuxSafeName('Web01'), 'Web01');
    });

    test('nothing that could end the command survives', () {
      // This is the security boundary. The result is interpolated into a command the *remote* runs,
      // so anything that gets through here runs there.
      expect(tmuxSafeName('x; rm -rf ~'), 'xrm-rf');
      expect(tmuxSafeName(r'x$(id)'), 'xid');
      expect(tmuxSafeName('x`id`'), 'xid');
      expect(tmuxSafeName('x && curl evil'), 'xcurlevil');
      expect(tmuxSafeName('x | tee /tmp/out'), 'xteetmpout');
      expect(tmuxSafeName("x'y\"z"), 'xyz');
      expect(tmuxSafeName('x\ny'), 'xy');
      expect(tmuxSafeName('x y'), 'xy');
    });

    test('a name that filters to nothing becomes a real one', () {
      // A blank `-t` would attach to whichever session tmux felt like.
      expect(tmuxSafeName(''), 'omniterm');
      expect(tmuxSafeName(';;;'), 'omniterm');
      expect(tmuxSafeName('   '), 'omniterm');
    });

    test('unicode is not a loophole', () {
      expect(tmuxSafeName('naïve-héllo'), 'nave-hllo');
      expect(tmuxSafeName('日本語'), 'omniterm');
    });
  });

  group('the attach commands', () {
    test('creating uses new-session and refuses to attach to an existing one', () {
      final command = tmuxCreateAttachCommand('nas-1');

      expect(command, contains('new-session -d -s nas-1'));
      expect(command, contains('exec tmux attach-session -t nas-1'));
      expect(
        command,
        isNot(contains('has-session')),
        reason: 'create must fail on a name collision rather than joining a stranger',
      );
    });

    test('attaching checks the session is there first', () {
      final command = tmuxAttachCommand('nas-1');

      expect(command, contains('has-session -t nas-1'));
      expect(command, isNot(contains('new-session')));
    });

    test('every command degrades to an ordinary shell without tmux', () {
      // A host with no tmux must leave the user at a working prompt, not a half-broken one.
      for (final command in [
        tmuxCreateAttachCommand('a'),
        tmuxAttachCommand('a'),
        tmuxControlAttachCommand('a'),
        tmuxControlCreateAttachCommand('a'),
      ]) {
        expect(command, startsWith('command -v tmux >/dev/null 2>&1 && '));
      }
    });

    test('the client replaces the login shell', () {
      // `exec`, so leaving tmux ends the SSH session instead of dropping the user at a bare prompt.
      expect(tmuxAttachCommand('a'), contains('exec tmux'));
      expect(tmuxCreateAttachCommand('a'), contains('exec tmux'));
    });

    test('control mode asks for a single -C', () {
      // `-CC` wraps the conversation in a DCS envelope meant for terminal-embedded clients, which
      // the parser does not speak.
      expect(tmuxControlAttachCommand('a'), contains('exec tmux -C attach-session'));
      expect(tmuxControlAttachCommand('a'), isNot(contains('-CC')));
      expect(tmuxControlCreateAttachCommand('a'), contains('exec tmux -C attach-session'));
    });

    test('mouse mode is turned off', () {
      // Scrolling is handled by the app against its own buffer; leaving tmux's mouse mode on sends
      // an ordinary drag into copy-mode, which looks like the terminal freezing.
      expect(tmuxAttachCommand('a'), contains('set-option -t a mouse off'));
      expect(tmuxCreateAttachCommand('a'), contains('set-option -t a mouse off'));
    });

    test('the scrollback limit is bounded, whatever it is asked for', () {
      expect(tmuxAttachCommand('a', historyLimit: 1), contains('history-limit $tmuxHistoryMin'));
      expect(
        tmuxAttachCommand('a', historyLimit: 10000000),
        contains('history-limit $tmuxHistoryMax'),
      );
      expect(tmuxAttachCommand('a', historyLimit: 5000), contains('history-limit 5000'));
    });

    test('a dangerous name is sanitised everywhere it appears in the command', () {
      // Not just in the `-t` argument: the same name reaches `set-option` and `new-session` too, and
      // one unsanitised occurrence is enough.
      final command = tmuxCreateAttachCommand('evil; rm -rf ~');

      expect(command, contains('new-session -d -s evilrm-rf'));
      expect(command, contains('attach-session -t evilrm-rf'));
      expect(command, contains('set-option -t evilrm-rf'));
      expect(command, isNot(contains('rm -rf')));
      expect(command, isNot(contains('evil;')));

      // The only `;` left is tmux's own command separator in the fixed template (`start-server \;
      // set-option`), which is why banning the character outright would be the wrong assertion.
      expect(
        command.replaceAll(r'\;', ''),
        isNot(contains(';')),
        reason: 'no semicolon may come from the name',
      );
    });
  });
}
