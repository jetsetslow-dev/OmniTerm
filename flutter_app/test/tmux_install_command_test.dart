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
