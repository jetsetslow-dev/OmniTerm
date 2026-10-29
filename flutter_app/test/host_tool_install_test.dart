import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:omniterm/data/host_tools.dart';

/// The tool installs run as written against stand-in package managers: what each one is asked to
/// install, how it elevates, and what it says when it cannot. Nothing here reads the machine running
/// the test: PATH holds only the stand-ins and the few standard tools the script itself uses.
/// Kotlin's `HostToolInstallTest`, case for case.
void main() {
  String? standardTool(String name) => [
    '/usr/bin',
    '/bin',
  ].map((dir) => '$dir/$name').where((p) => File(p).existsSync()).firstOrNull;
  final sh = ['/bin/sh', '/usr/bin/sh', '/bin/dash'].where((p) => File(p).existsSync()).firstOrNull;
  const needed = ['awk', 'sed', 'head', 'chmod', 'timeout'];
  final skip = sh == null || needed.any((t) => standardTool(t) == null)
      ? 'POSIX sh and ${needed.join(', ')} are required'
      : null;

  /// Runs [script] with [fakes] (name to sh body) on PATH, feeding [stdin].
  Future<({String output, int exitCode, List<String> log})> run(
    String script,
    Map<String, String> fakes, {
    String? stdin,
  }) async {
    final dir = Directory.systemTemp.createTempSync('omniterm-tool-install');
    try {
      final bin = Directory('${dir.path}/fakes')..createSync();
      final tools = Directory('${dir.path}/tools')..createSync();
      for (final tool in needed) {
        Link('${tools.path}/$tool').createSync(standardTool(tool)!);
      }
      final log = File('${dir.path}/log')..writeAsStringSync('');
      for (final MapEntry(key: name, value: body) in fakes.entries) {
        final file = File('${bin.path}/$name')..writeAsStringSync('#!$sh\n$body\n');
        Process.runSync(standardTool('chmod')!, ['+x', file.path]);
      }
      final process = await Process.start(
        sh!,
        ['-c', script],
        environment: {
          'PATH': '${bin.path}:${tools.path}',
          'FAKES': bin.path,
          'LOG': log.path,
          'STATE': dir.path,
        },
        includeParentEnvironment: false,
      );
      try {
        if (stdin != null) process.stdin.write(stdin);
        await process.stdin.close();
      } on IOException {
        // A script that never reads stdin may have exited first; what it printed still counts.
      }
      final out = StringBuffer();
      await Future.wait([
        process.stdout.transform(const SystemEncoding().decoder).forEach(out.write),
        process.stderr.transform(const SystemEncoding().decoder).forEach(out.write),
      ]);
      final code = await process.exitCode;
      return (
        output: out.toString(),
        exitCode: code,
        log: log.readAsLinesSync().where((l) => l.trim().isNotEmpty).toList(),
      );
    } finally {
      dir.deleteSync(recursive: true);
    }
  }

  const notRoot = r'[ "$1" = -u ] && echo 1000';

  // Logs how it was called, insists on an empty prompt, checks the password once as real sudo
  // does (then trusts the timestamp), and runs the command.
  const sudo = r'''
echo "sudo $*" >> "$LOG"
mode=
while [ $# -gt 0 ]; do case $1 in -S|-n) mode=$1; shift;; -p) [ -z "$2" ] || { echo "sudo: unexpected prompt" >&2; exit 1; }; shift 2;; *) break;; esac; done
if [ ! -e "$STATE/sudo-ok" ]; then
  if [ "$mode" = -n ]; then echo "sudo: a password is required" >&2; exit 1; fi
  read -r pw || pw=
  [ "$pw" = fixture-sudo ] || { echo "sudo: incorrect password" >&2; exit 1; }
  : > "$STATE/sudo-ok"
fi
exec "$@"''';

  // Installing anything also puts nvidia-smi on PATH, as the real package does.
  const aptGet = r'''
echo "apt-get $*" >> "$LOG"
if [ "$1" = install ]; then printf '#!/bin/sh\necho ok\n' > "$FAKES/nvidia-smi"; chmod +x "$FAKES/nvidia-smi"; fi''';

  const ubuntuServerDriver = r'''
printf 'ii nvidia-kernel-common-595-server 595.91.07-0ubuntu0.26.04.2\n'
printf 'un nvidia-kernel-common-595-server-595.91.07 \n'
''';

  test('nvidia-smi on Ubuntu comes from the loaded driver\'s own branch and version', () async {
    final r = await run(HostTool.nvidiaSmi.installCommand(), {
      'id': notRoot,
      'sudo': sudo,
      'apt-get': aptGet,
      'dpkg-query': ubuntuServerDriver,
    }, stdin: 'fixture-sudo\n');
    expect(r.exitCode, 0, reason: r.output);
    expect(r.output.trim(), endsWith('nvidia-smi installed'));
    expect(r.log, [
      'sudo -S -p  apt-get update',
      'apt-get update',
      // nvidia-utils-595 (not -server) is a newer build; it would answer only
      // "Driver/library version mismatch" against this module.
      'sudo -S -p  apt-get install -y nvidia-utils-595-server=595.91.07-0ubuntu0.26.04.2',
      'apt-get install -y nvidia-utils-595-server=595.91.07-0ubuntu0.26.04.2',
    ]);
  }, skip: skip);

  test('Debian without Ubuntu\'s driver packages installs its own nvidia-smi', () async {
    final r = await run(HostTool.nvidiaSmi.installCommand(), {
      'id': notRoot,
      'sudo': sudo,
      'apt-get': aptGet,
      'dpkg-query': 'exit 1',
    }, stdin: 'fixture-sudo\n');
    expect(r.exitCode, 0, reason: r.output);
    expect(r.log, contains('apt-get install -y nvidia-smi'));
  }, skip: skip);

  test('without a saved password sudo refuses instead of waiting for one', () async {
    final r = await run(HostTool.nvidiaSmi.installCommand(withSudoPassword: false), {
      'id': notRoot,
      'sudo': sudo,
      'apt-get': aptGet,
      'dpkg-query': ubuntuServerDriver,
    });
    expect(r.exitCode, 1);
    expect(r.output, contains('sudo: a password is required'));
    expect(r.log, ['sudo -n -p  apt-get update']);
  }, skip: skip);

  test('as root nothing goes through sudo', () async {
    final r = await run(HostTool.nvidiaSmi.installCommand(), {
      'id': r'[ "$1" = -u ] && echo 0',
      'sudo': sudo,
      'apt-get': aptGet,
      'dpkg-query': ubuntuServerDriver,
    });
    expect(r.exitCode, 0, reason: r.output);
    expect(r.log.where((l) => l.startsWith('sudo')), isEmpty);
  }, skip: skip);

  test('a package manager without the package says so and installs nothing', () async {
    final r = await run(HostTool.nvidiaSmi.installCommand(), {
      'id': notRoot,
      'sudo': sudo,
      'apk': r'echo "apk $*" >> "$LOG"',
    }, stdin: 'fixture-sudo\n');
    expect(r.exitCode, 1);
    expect(
      r.output,
      contains('OmniTerm cannot install nvidia-smi with apk: it has no nvidia-smi package.'),
    );
    expect(r.log, isEmpty);
  }, skip: skip);

  test('a tool already there is left alone', () async {
    final r = await run(HostTool.nvidiaSmi.installCommand(), {
      'id': notRoot,
      'sudo': sudo,
      'apt-get': aptGet,
      'nvidia-smi': 'echo ok',
    });
    expect(r.exitCode, 0);
    expect(r.output.trim(), 'nvidia-smi is already installed');
    expect(r.log, isEmpty);
  }, skip: skip);

  test('the check answers only once the tool is there', () async {
    expect((await run(HostTool.nvidiaSmi.checkCommand(), {})).output.trim(), 'no');
    expect(
      (await run(HostTool.nvidiaSmi.checkCommand(), {'nvidia-smi': 'echo ok'})).output.trim(),
      'yes',
    );
  }, skip: skip);
}
