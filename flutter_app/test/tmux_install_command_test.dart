import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:omniterm/data/remote_commands.dart';

/// The tmux presence check and installer, ported from `RemoteCommands.TMUX_CHECK` and
/// `tmuxInstallCommand()` (`data/RemoteParsers.kt:140`, `:303`).
///
/// The installer is **never executed** here — it would install a package on whatever machine runs
/// the suite. It is parsed with `sh -n` instead, which catches the failure mode a hand-built shell
/// string actually has: an unbalanced quote or `fi` that only shows up on a user's server, halfway
/// through a connection they were waiting on.
void main() {
  const sh = '/bin/sh';

  /// The probe's *answer*, which is a different question from the command.
  ///
  /// `exec` reports transport failure by returning `'SSH Error: …'` rather than throwing, so the
  /// old `answer.trim().endsWith('yes')` test read a refused connection, a timeout or a rejected
  /// key as a definite "tmux is not installed" — and the app then offered to install a package
  /// over a connection that did not exist.
  group('parseTmuxCheck', () {
    test('yes is present and no is absent', () {
      expect(parseTmuxCheck('yes'), isTrue);
      expect(parseTmuxCheck('no'), isFalse);
      expect(parseTmuxCheck('  yes \n'), isTrue);
      expect(parseTmuxCheck('no\r\n'), isFalse);
    });

    test('a login banner before the answer does not hide it', () {
      expect(parseTmuxCheck('Welcome to Ubuntu 24.04 LTS\n\nyes'), isTrue);
      expect(parseTmuxCheck('Last login: Sat Sep 13\nno\n'), isFalse);
    });

    test('a returned transport error is unverified, never absent', () {
      for (final raw in [
        'SSH Error: Connection refused',
        'SSH Error: SSHAuthFailError',
        'SSH Error: command timed out',
      ]) {
        expect(parseTmuxCheck(raw), isNull, reason: raw);
      }
    });

    test('an empty or unrecognised answer is unverified', () {
      expect(parseTmuxCheck(''), isNull);
      expect(parseTmuxCheck('   \n  '), isNull);
      expect(parseTmuxCheck('bash: command: not found'), isNull);
    });

    test('a word merely ending in the answer is not the answer', () {
      // `endsWith('yes')` matched all of these. They are not what `echo yes` prints.
      expect(parseTmuxCheck('kangaroo'), isNull, reason: 'ends in "roo", not the point');
      expect(parseTmuxCheck('eyes'), isNull);
      expect(parseTmuxCheck('SSH Error: bad bytes'), isNull);
    });
  });

  group('tmuxCheckCommand', () {
    test('answers yes or no against a real shell', () {
      final run = Process.runSync(sh, ['-c', tmuxCheckCommand]);
      expect(run.exitCode, 0);
      expect((run.stdout as String).trim(), anyOf('yes', 'no'));
    });

    test('answers for a PATH with no tmux', () {
      // An empty PATH is the reliable way to stage "not installed" without touching the machine.
      final run = Process.runSync(
        sh,
        ['-c', tmuxCheckCommand],
        environment: {'PATH': '/nonexistent'},
        includeParentEnvironment: false,
      );
      expect((run.stdout as String).trim(), 'no');
    });
  });

  group('tmuxInstallCommand', () {
    test('is valid shell', () {
      // `sh -n` parses without executing.
      final run = Process.runSync(sh, ['-n', '-c', tmuxInstallCommand()]);
      expect(run.exitCode, 0, reason: 'the installer must parse: ${run.stderr}');
    });

    test('covers every package manager Kotlin covers', () {
      final command = tmuxInstallCommand();
      for (final manager in const ['apt-get', 'dnf', 'yum', 'pacman', 'apk', 'zypper', 'pkg']) {
        expect(command, contains(manager), reason: '$manager branch is missing');
      }
    });

    test('takes the sudo password on stdin, never on the command line', () {
      // `sudo -S` reads it from stdin. Interpolating it here would put it in `ps` output and auditd
      // execve records on the remote, which is the whole reason [sudoStdin] exists.
      expect(tmuxInstallCommand(), contains('sudo -S'));
      expect(tmuxInstallCommand(), isNot(contains('sudo -p')));
    });

    test('skips sudo entirely when already root', () {
      expect(tmuxInstallCommand(), contains(r'if [ "$(id -u)" = 0 ]; then SUDO='));
    });

    test('exits early when tmux is already there', () {
      expect(tmuxInstallCommand(), contains('tmux already installed'));
    });

    test('re-checks rather than trusting the package manager exit code', () {
      // Several of these return 0 for "nothing to do" against a broken mirror. Reporting a
      // successful install of something that is not there sends the user back to a non-resumable
      // shell with no explanation.
      final command = tmuxInstallCommand();
      expect(command.lastIndexOf('command -v tmux'), greaterThan(command.indexOf('apt-get')));
      expect(command, contains('tmux install failed'));
    });

    test('says so plainly when it cannot help', () {
      expect(
        tmuxInstallCommand(),
        contains('No supported package manager found; install tmux manually.'),
      );
    });
  });
}
