import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:omniterm/data/remote_commands.dart';
import 'package:omniterm/data/remote_models.dart';
import 'package:omniterm/data/remote_parsers.dart';

/// Every host action picks the command its OS understands.
///
/// The BSD and macOS service lists are shell logic over tools this machine does not have, so they
/// run against small fake `service`, `rcctl`, `launchctl` and `id` scripts that print what the real
/// tools print. That checks the parsing loop itself rather than only the command text.
///
/// Mirrors `HostOsCommandsTest` in the Kotlin app.
void main() {
  Map<String, SimService> services(String output) => {
    for (final s in parseServices(output)) s.name: s,
  };

  void expectService(SimService? service, String status, {required bool enabled}) {
    expect(service, isNotNull);
    expect(service!.status, status, reason: service.name);
    expect(service.enabled, enabled, reason: service.name);
  }

  /// Runs [script] with only [fakes] and the base system tools on PATH, or null without a POSIX sh.
  String? runWithFakes(String script, Map<String, String> fakes) {
    if (!File('/bin/sh').existsSync()) return null;
    final dir = Directory.systemTemp.createTempSync('omniterm-fake-tools');
    try {
      fakes.forEach((name, body) {
        final file = File('${dir.path}/$name')..writeAsStringSync('#!/bin/sh\n$body\n');
        Process.runSync('chmod', ['+x', file.path]);
      });
      final result = Process.runSync(
        '/bin/sh',
        ['-c', script],
        environment: {'PATH': '${dir.path}:/usr/bin:/bin'},
        includeParentEnvironment: false,
      );
      return '${result.stdout}${result.stderr}';
    } finally {
      dir.deleteSync(recursive: true);
    }
  }

  test('each OS gets its own service list', () {
    expect(servicesFor('Linux'), servicesCommand);
    expect(servicesFor('FreeBSD'), servicesBsd);
    expect(servicesFor('OpenBSD'), servicesBsd);
    expect(servicesFor('Darwin'), servicesDarwin);
    expect(servicesFor('Windows'), servicesWindows);
  });

  test('FreeBSD services come from rc.d', () {
    final out = runWithFakes(servicesBsd, {
      'service': r'''
case "$1" in
  -e) printf '/etc/rc.d/sshd\n/usr/local/etc/rc.d/nginx\n';;
  -l) printf 'DAEMON\nLOGIN\nnginx\nntpd\nsshd\n';;
  sshd|ntpd) [ "$2" = onestatus ] && exit 0; exit 1;;
  *) exit 1;;
esac''',
    });
    if (out == null) return;
    final list = services(out);
    expect(list.keys.toSet(), {'nginx', 'ntpd', 'sshd'});
    expectService(list['sshd'], 'running', enabled: true);
    expectService(list['nginx'], 'dead', enabled: true);
    expectService(list['ntpd'], 'running', enabled: false);
  });

  test('OpenBSD services come from rcctl', () {
    final out = runWithFakes(servicesBsd, {
      'rcctl': r'''
case "$1 $2" in
  "ls all") printf 'ntpd\nsmtpd\nsshd\n';;
  "ls on") printf 'smtpd\nsshd\n';;
  "ls started") printf 'sshd\n';;
esac''',
    });
    if (out == null) return;
    final list = services(out);
    expectService(list['sshd'], 'running', enabled: true);
    expectService(list['smtpd'], 'dead', enabled: true);
    expectService(list['ntpd'], 'dead', enabled: false);
  });

  const launchctl = r'''
case "$1" in
  print) exit 0;;
  print-disabled) printf 'disabled services = {\n\t"com.example.off" => disabled\n\t"com.example.web" => enabled\n}\n';;
  list) printf 'PID\tStatus\tLabel\n412\t0\tcom.example.web\n-\t0\tcom.example.off\n-\t78\tcom.example.crashy\n';;
  *) echo "launchctl $*";;
esac''';

  test('macOS services come from launchd', () {
    final out = runWithFakes(servicesDarwin, {'launchctl': launchctl, 'id': 'echo 501'});
    if (out == null) return;
    final list = services(out);
    expectService(list['com.example.web'], 'running', enabled: true);
    expectService(list['com.example.off'], 'dead', enabled: false);
    expectService(list['com.example.crashy'], 'failed', enabled: true);
  });

  test('macOS service actions use the domain the list came from', () {
    final out = runWithFakes(serviceAction('com.example.web', 'restart', os: 'Darwin'), {
      'launchctl': launchctl,
      'id': 'echo 501',
    });
    if (out == null) return;
    expect(out.trim(), 'launchctl kickstart -k gui/501/com.example.web');
    expect(serviceActionUsesSudo('Darwin'), isFalse);
  });

  test('Windows services read their status and start type', () {
    const out =
        '---SERVICE-TABLE---\r\n'
        'Spooler\tRunning\tAutomatic\tPrint Spooler\r\n'
        'wuauserv\tStopped\tManual\tWindows Update\r\n'
        'BITS\tRunning\tAutomaticDelayedStart\tBackground Intelligent Transfer Service\r\n'
        'Fax\tStopped\tDisabled\tFax\r\n';
    final list = services(out);
    expectService(list['Spooler'], 'running', enabled: true);
    expectService(list['wuauserv'], 'dead', enabled: false);
    expectService(list['BITS'], 'running', enabled: true);
    expectService(list['Fax'], 'dead', enabled: false);
    expect(list['Spooler']?.desc, 'Print Spooler');
    expect(servicesWindows, startsWith('powershell '));
  });

  test('service actions speak each service manager', () {
    final bsd = serviceAction('sshd', 'start', sudoPassword: 'pw', os: 'FreeBSD');
    expect(bsd, startsWith("sudo -S -p '' sh -c "));
    expect(bsd, allOf(contains('rcctl start '), contains('service '), contains(' onestart')));
    expect(serviceActionUsesSudo('FreeBSD'), isTrue);

    expect(
      serviceAction('Spooler', 'restart', sudoPassword: 'pw', os: 'Windows'),
      "powershell -NoProfile -Command \"Restart-Service -Name 'Spooler' -Force\"",
    );
    expect(serviceAction("it's", 'stop', os: 'Windows'), contains("-Name 'it''s'"));
    expect(serviceAction('50%', 'stop', os: 'Windows'), isNot(contains('powershell')));
    expect(serviceActionUsesSudo('Windows'), isFalse);

    // sudoShWrap quotes the whole script again, so the name's own quotes come out as '\''.
    final linux = serviceAction('nginx', 'restart', os: 'Linux');
    expect(linux, allOf(contains('systemctl restart '), contains('nginx'), contains('rc-service')));
  });

  test('reboot uses each OS shutdown', () {
    expect(rebootCommand(sudoPassword: 'pw', os: 'Windows'), 'shutdown /r /t 0 2>&1');
    expect(rebootUsesSudo('Windows'), isFalse);
    expect(
      rebootCommand(sudoPassword: 'pw', os: 'FreeBSD'),
      startsWith("sudo -S -p '' shutdown -r now"),
    );
    expect(rebootCommand(os: 'Darwin'), startsWith('sudo -n shutdown -r now'));
    expect(rebootCommand(os: 'Linux'), startsWith('sudo -n reboot'));
    expect(rebootLabel('Linux'), 'sudo reboot');
    expect(rebootLabel('FreeBSD'), 'sudo shutdown -r now');
    expect(rebootLabel('Windows'), 'shutdown /r /t 0');
  });

  test('ending a process uses taskkill on Windows', () {
    expect(killProcessCommand(42, os: 'Windows'), 'taskkill /PID 42 2>&1');
    expect(killProcessCommand(42, signal: 9, os: 'Windows'), 'taskkill /PID 42 /F 2>&1');
    expect(killProcessCommand(42, signal: 9, os: 'Linux'), 'kill -9 42 2>&1');
    expect(killProcessCommand(42, os: 'Darwin'), 'kill -15 42 2>&1');
  });

  test('fleet checks ask Windows in PowerShell', () {
    for (final check in QuickCheck.values) {
      expect(
        quickCheckCommand(check, 'Windows'),
        startsWith('powershell -NoProfile -Command "'),
        reason: check.name,
      );
    }
    expect(quickCheckCommand(QuickCheck.uptime, 'FreeBSD'), 'uptime');
    expect(quickCheckCommand(QuickCheck.disk, 'Linux'), 'df -h');
    expect(quickCheckCommand(QuickCheck.processes, ''), 'ps aux | head -5');
  });

  test('only Windows lacks a Unix shell', () {
    expect(hasUnixShell('Windows'), isFalse);
    for (final os in ['Linux', 'FreeBSD', 'Darwin', '']) {
      expect(hasUnixShell(os), isTrue, reason: os);
    }
  });

  test('a PowerShell login shell is recognised as Windows', () {
    const parseError = '''
At line:1 char:22
+ uname -s 2>/dev/null || echo Windows
+                      ~~
The token '||' is not a valid statement separator in this version.
    + CategoryInfo          : ParserError: (:) [], ParentContainsErrorRecordException''';
    expect(normaliseOs(parseError), 'Windows');
  });

  test('BSD and macOS disk sizes come from POSIX df in kilobytes', () {
    // Without -P, macOS adds inode columns that end up in the mount point.
    for (final metrics in [metricsBsd, metricsDarwin]) {
      expect(metrics, contains('df -Pk / '));
      expect(metrics, contains('df -Pk 2>'));
      expect(metrics, isNot(contains('df -k')));
    }
  });

  test("BusyBox's df -Pk fallback is scaled to bytes", () {
    final disks = parseDisks('KB1024 /dev/sda1 1000 400 600 40% /data');
    expect(disks.single.totalBytes, 1000 * 1024);
    expect(disks.single.usedBytes, 400 * 1024);
  });
}
