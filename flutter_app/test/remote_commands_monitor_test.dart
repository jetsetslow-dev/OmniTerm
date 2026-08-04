import 'package:flutter_test/flutter_test.dart';
import 'package:omniterm/data/remote_commands.dart';

/// Requirement 12: a name the user (or a remote host) supplied must never become a command, and a
/// sudo password must never appear in one.
void main() {
  group('shellQuote', () {
    test('wraps a plain value', () {
      expect(shellQuote('nginx'), "'nginx'");
    });

    test('neutralises every shell metacharacter', () {
      // Inside single quotes the shell expands nothing, so each of these stays literal text.
      for (final payload in [
        r'a; rm -rf /',
        r'a && rm -rf /',
        r'a | tee /etc/passwd',
        r'$(id)',
        '`id`',
        r'a $HOME b',
        'a\nrm -rf /',
        'a > /etc/shadow',
        'a*',
      ]) {
        final quoted = shellQuote(payload);
        expect(quoted.startsWith("'"), isTrue);
        expect(quoted.endsWith("'"), isTrue);
        // The payload survives verbatim between the quotes: nothing was stripped or interpreted.
        expect(quoted.substring(1, quoted.length - 1), payload);
      }
    });

    test('an embedded single quote cannot end the quoting', () {
      // This is the one escape that matters: close, escaped literal quote, reopen.
      expect(shellQuote("it's"), r"'it'\''s'");
      expect(shellQuote(r"'; rm -rf /; '"), r"''\''; rm -rf /; '\'''");
    });

    test('an empty value still produces a quoted empty argument', () {
      // Unquoted, an empty variable disappears and shifts every later argument by one position.
      expect(shellQuote(''), "''");
    });
  });

  group('sudo', () {
    const password = 'hunter2';

    test('the password never appears in the command string', () {
      // A command line is visible in `ps`, auditd execve records and sshd debug logs on the remote.
      expect(sudoWrap('reboot', password), isNot(contains(password)));
      expect(sudoShWrap('cp a b && rm a', password), isNot(contains(password)));
      expect(serviceAction('nginx', 'restart', sudoPassword: password), isNot(contains(password)));
      expect(rebootCommand(sudoPassword: password), isNot(contains(password)));
    });

    test('it travels via stdin instead', () {
      expect(
        sudoStdin(password),
        'hunter2\n',
        reason: 'sudo -S reads the password and the newline it waits for from stdin',
      );
    });

    test('a NOPASSWD host sends no stdin at all', () {
      expect(sudoStdin(''), isNull);
      expect(sudoStdin('   '), isNull);
    });

    test('with a password it uses -S and suppresses the prompt', () {
      final cmd = sudoWrap('reboot', password);
      expect(cmd, contains('sudo -S'));
      expect(cmd, contains("-p ''"), reason: 'the prompt must not be echoed into the output');
    });

    test('without a password it uses non-interactive sudo rather than hanging', () {
      expect(sudoWrap('reboot', ''), contains('sudo -n'));
    });

    test('sudoShWrap elevates the whole script, not just its first command', () {
      // `sudo a && b` runs b as the ordinary user; this is why the script form exists.
      expect(sudoShWrap('cp a b && rm a', ''), contains("sh -c 'cp a b && rm a'"));
    });
  });

  group('serviceAction', () {
    test('quotes the unit name', () {
      final cmd = serviceAction(r'evil; rm -rf /', 'restart');
      expect(cmd, isNot(contains('; rm -rf /;')));
      expect(cmd, contains(r"evil; rm -rf /"), reason: 'it survives as literal text');
      // Every occurrence of the name is inside quotes, for both the systemd and OpenRC branches.
      expect(RegExp(r"systemctl restart '").hasMatch(cmd), isTrue);
    });

    test('covers both systemd and OpenRC, and fails loudly on neither', () {
      final cmd = serviceAction('nginx', 'restart');
      expect(cmd, contains('systemctl restart'));
      expect(cmd, contains('rc-service'));
      expect(
        cmd,
        contains('exit 1'),
        reason: 'a host with no service manager must report that, not silently succeed',
      );
    });

    test('enable and disable use the right OpenRC verbs', () {
      expect(serviceAction('nginx', 'enable'), contains('rc-update add'));
      expect(serviceAction('nginx', 'disable'), contains('rc-update delete'));
    });
  });

  group('per-OS variants', () {
    test('processes picks the right ps for each family', () {
      expect(processesFor('Linux'), processesLinux);
      expect(processesFor('FreeBSD'), processesBsd);
      expect(processesFor('Darwin'), processesBsd);
      expect(processesFor('Windows'), processesWindows);
      expect(processesFor(''), processesLinux, reason: 'unknown resolves to the safest superset');
    });

    test('the Linux process command falls back for BusyBox', () {
      // BusyBox ps has no -eo; without the fallback the tab would be empty on OpenWrt.
      expect(processesLinux, contains('|| ps w'));
    });

    test('logs fall through every source a non-systemd host might have', () {
      final linux = journalCommand();
      for (final source in ['journalctl', 'logread', '/var/log/messages', '/var/log/syslog']) {
        expect(linux, contains(source));
      }
      expect(
        linux,
        contains('---NOLOGS---'),
        reason: 'the UI needs to distinguish "no log source" from "no log lines"',
      );
    });

    test('each log source is tried until one produces output', () {
      // Not `elif`. A BusyBox host ships `logread` whether or not syslogd is running; when it is
      // not, `logread` fails to stderr and exits, so a chain that branches on the binary merely
      // *existing* stopped there, printed nothing, never emitted the marker, and left the pane
      // silently blank on most containers. Verified against a real Alpine host (§15.10).
      final linux = journalCommand();
      expect(linux, isNot(contains('elif')));
      // Every later source is guarded on the accumulated output still being empty.
      expect(r'[ -z "$L" ]'.allMatches(linux).length, greaterThanOrEqualTo(3));
      expect(linux, contains(r'printf'), reason: 'the collected output is what gets emitted');
    });

    test('the log line count is honoured', () {
      expect(journalCommand(lines: 42), contains('-n 42'));
    });

    test('macOS and Windows get their own log sources', () {
      expect(journalCommand(os: 'Darwin'), contains('log show'));
      expect(journalCommand(os: 'Windows'), contains('Get-WinEvent'));
    });

    test('services detects the init system rather than assuming systemd', () {
      expect(servicesCommand, contains('command -v systemctl'));
      expect(servicesCommand, contains('---OPENRC---'));
      expect(servicesCommand, contains('---NOSYSTEMD---'));
    });
  });

  test('reboot falls back to a bare reboot for already-root hosts', () {
    expect(rebootCommand(), contains('|| reboot'));
  });

  test('kill uses the requested signal', () {
    expect(killProcessCommand(1234), contains('kill -15 1234'));
    expect(killProcessCommand(1234, signal: 9), contains('kill -9 1234'));
  });
}
