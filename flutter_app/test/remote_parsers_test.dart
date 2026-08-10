import 'package:flutter_test/flutter_test.dart';
import 'package:omniterm/data/remote_commands.dart';
import 'package:omniterm/data/remote_models.dart';
import 'package:omniterm/data/remote_parsers.dart';

/// Deterministic tests for the SSH output parsers, using captured sample command output.
///
/// Ported from `RemoteParsersTest.kt` and `MetricsParsersTest.kt`. The sample outputs are copied
/// verbatim from the Kotlin tests, so these assert the *same* behaviour against the *same* fixtures
/// — which is what makes them evidence the port is faithful rather than merely self-consistent.
///
/// Fixtures are inline strings, never output from the dev machine, so the suite stays
/// host-independent.
void main() {
  group('normaliseOs', () {
    test('maps the OS families', () {
      expect(normaliseOs('Linux\n'), 'Linux');
      expect(normaliseOs('FreeBSD'), 'FreeBSD');
      expect(normaliseOs('Darwin'), 'Darwin');
      expect(normaliseOs('Windows'), 'Windows');
      expect(
        normaliseOs("'uname' is not recognized as an internal or external command"),
        'Windows',
      );
      // Unknown unix -> Linux superset.
      expect(normaliseOs('SunOS'), 'Linux');
    });

    test('an absent @OS section falls back to Linux', () {
      expect(normaliseOs(''), 'Linux');
    });
  });

  group('parseProcesses', () {
    test('parses ps output', () {
      // Columns: pid user %cpu %mem vsz etime stat comm
      const out =
          '1234 root      2.5  1.2 123456 01:02:03 S    nginx\n'
          '5678 deploy   10.0  4.0 654321 10-00:00 Rl   node';
      final procs = parseProcesses(out);
      expect(procs, hasLength(2));
      expect(procs[0].pid, 1234);
      expect(procs[0].owner, 'root');
      expect(procs[0].cpu, closeTo(2.5, 0.001));
      expect(procs[0].uptime, '01:02:03');
      expect(procs[0].name, 'nginx');
      expect(procs[1].state, 'R', reason: 'first char of "Rl"');
    });

    test('reads etime and skips the header row', () {
      const out =
          'PID USER %CPU %MEM VSZ ELAPSED STAT COMMAND\n'
          '101 root 12.5 3.2 204800 01:23:45 R nginx\n'
          '202 www 1.0 0.5 102400 2-03:04:05 S php-fpm';
      final procs = parseProcesses(out);
      expect(procs, hasLength(2), reason: 'the header\'s first column is not an integer');
      expect(procs[0].pid, 101);
      expect(procs[0].uptime, '01:23:45');
      expect(procs[0].name, 'nginx');
      expect(procs[0].state, 'R');
      expect(procs[1].uptime, '2-03:04:05');
    });

    test('BusyBox 4-column form keeps a command containing spaces intact', () {
      // PID USER TIME COMMAND — the command must not be truncated at its first space.
      const out = '1 root 0:00 /sbin/init --verbose splash';
      final procs = parseProcesses(out);
      expect(procs, hasLength(1));
      expect(procs.single.name, '/sbin/init --verbose splash');
      expect(procs.single.uptime, '0:00');
      expect(procs.single.vms, '—', reason: 'BusyBox reports no VSZ');
      expect(procs.single.cpu, 0);
    });
  });

  group('parseServices', () {
    test('parses systemctl units', () {
      const out =
          'ssh.service     loaded active running OpenBSD Secure Shell server\n'
          'cron.service    loaded active running Regular background program processing daemon\n'
          'broke.service   loaded failed failed  A broken unit';
      final svcs = parseServices(out);
      expect(svcs, hasLength(3));
      expect(svcs[0].name, 'ssh');
      expect(svcs[0].status, 'running');
      expect(svcs[0].subState, 'active');
      expect(svcs[2].status, 'failed');
      expect(svcs[2].subState, 'failed');
    });

    test('parses a unit with a leading status bullet', () {
      // Some systemd builds emit a leading "●" marker even with --plain; the unit must still parse
      // rather than being dropped.
      const out = '● nginx.service loaded active running A high performance web server';
      final svcs = parseServices(out);
      expect(svcs, hasLength(1));
      expect(svcs[0].name, 'nginx');
      expect(svcs[0].status, 'running');
      expect(svcs[0].subState, 'active');
    });

    test('reads enabled state from the ---ENABLED--- section', () {
      const out =
          'ssh.service loaded active running Secure Shell\n'
          'cron.service loaded active running Cron\n'
          '---ENABLED---\n'
          'ssh.service enabled\n'
          'cron.service disabled';
      final svcs = parseServices(out);
      expect(svcs.firstWhere((s) => s.name == 'ssh').enabled, isTrue);
      expect(svcs.firstWhere((s) => s.name == 'cron').enabled, isFalse);
    });

    test('parses OpenRC rc-status output', () {
      const out =
          '---OPENRC---\n'
          ' sshd   [  started  ]\n'
          ' crond  [  crashed  ]\n'
          ' nfs    [  stopped  ]\n'
          'Runlevel: default';
      final svcs = parseServices(out);
      expect(svcs.map((s) => s.name).toList(), ['sshd', 'crond', 'nfs']);
      expect(svcs[0].status, 'running');
      expect(svcs[1].status, 'failed');
      expect(svcs[2].status, 'dead');
      expect(
        svcs.every((s) => s.enabled),
        isTrue,
        reason: 'runlevel attachment is OpenRC\'s closest notion of "enabled"',
      );
    });
  });

  group('parseJournal', () {
    test('extracts time, source and infers level', () {
      const out =
          '2026-05-30T10:41:22+0000 host sshd[123]: Accepted publickey for deploy\n'
          '2026-05-30T10:42:00+0000 host nginx[9]: connect() failed (111: Connection refused)';
      final logs = parseJournal(out);
      expect(logs, hasLength(2));
      expect(logs[0].time, '10:41:22');
      expect(logs[0].source, 'sshd');
      expect(logs[0].level, 'INFO');
      expect(logs[1].source, 'nginx');
      expect(logs[1].level, 'ERROR');
    });

    test('skips banners and the no-logs marker', () {
      const out = '-- Logs begin at Fri 2026-05-30 --\n---NOLOGS---\n';
      expect(parseJournal(out), isEmpty);
      expect(journalUnsupported(out), isTrue);
      expect(journalUnsupported('some real log line'), isFalse);
    });

    test('an unparseable line still surfaces as an INFO message', () {
      // Dropping it would silently hide log content from the user.
      final logs = parseJournal('something entirely unstructured');
      expect(logs, hasLength(1));
      expect(logs.single.message, 'something entirely unstructured');
      expect(logs.single.source, 'system');
      expect(logs.single.level, 'INFO');
    });

    test('WARN is inferred from warning vocabulary', () {
      for (final msg in ['a warning was raised', 'connection timeout', 'will retry shortly']) {
        final logs = parseJournal('2026-05-30T10:41:22+0000 host app[1]: $msg');
        expect(logs.single.level, 'WARN', reason: msg);
      }
    });

    test('severity stems match whole words, fixing the upstream boundary bug', () {
      // The Kotlin patterns were \b(...)\b, and the trailing \b disabled every stem: "fail" could
      // not match "failure", "error" could not match "errors", and "deprecat" — plainly written as
      // a stem — matched only the literal string "deprecat". These lines were all INFO in the
      // shipped app. See MIGRATION.md §7.8.
      String levelOf(String message) =>
          parseJournal('2026-05-30T10:41:22+0000 host app[1]: $message').single.level;

      expect(levelOf('connection failure'), 'ERROR');
      expect(levelOf('disk errors detected'), 'ERROR');
      expect(levelOf('task is failing'), 'ERROR');
      expect(levelOf('deprecated option in use'), 'WARN');
      expect(levelOf('deprecation notice'), 'WARN');
      expect(levelOf('warned twice'), 'WARN');
      expect(levelOf('retrying now'), 'WARN');
      expect(levelOf('timeouts observed'), 'WARN');
    });

    test('a stem still has to start a word, so it cannot match mid-token', () {
      String levelOf(String message) =>
          parseJournal('2026-05-30T10:41:22+0000 host app[1]: $message').single.level;
      // The leading \b is retained: these must not be dragged up to ERROR/WARN.
      expect(levelOf('shutdown complete'), 'INFO');
      expect(levelOf('unswarned'), 'INFO');
    });

    test('fleet entries prefix a non-system source', () {
      final entries = parseFleetJournal(
        '2026-05-30T10:41:22+0000 host sshd[123]: Accepted publickey',
        'nas',
        7,
      );
      expect(entries.single.serverName, 'nas');
      expect(entries.single.serverId, 7);
      expect(entries.single.message, '[sshd] Accepted publickey');
    });
  });

  group('parseRuntimeList', () {
    test('accepts only the two runtime names', () {
      expect(parseRuntimeList('docker\npodman\n'), {'docker', 'podman'});
      expect(parseRuntimeList('  podman  \n'), {'podman'});
      expect(parseRuntimeList(''), isEmpty);
      // Noise (motd banners, errors) must not register as a runtime.
      expect(parseRuntimeList('Welcome to host\ndocker\nbash: podman: command not found'), {
        'docker',
      });
    });
  });

  group('parseDockerPs', () {
    test('parses both runtimes, health and compose labels', () {
      const out =
          'podman\tabc123\tweb\tnginx:1.25\tUp 3 hours (healthy)\t80/tcp\tmyproj\tweb\t/opt/app\tcompose.yml\t2026-05-01 00:00:00 +0000 UTC\n'
          'docker\tdef456\tdb\tpostgres:16\tExited (0) 2 hours ago\t\t\t\t\t\t2026-05-02 00:00:00 +0000 UTC';
      final containers = parseDockerPs(out);
      expect(containers, hasLength(2));
      expect(containers[0].name, 'web');
      expect(containers[0].runtime, 'podman');
      expect(containers[0].status, 'running');
      expect(containers[0].group, 'myproj');
      expect(containers[0].composeService, 'web');
      expect(containers[0].health, 'healthy');
      expect(containers[1].status, 'exited');
      expect(containers[1].runtime, 'docker');
      expect(containers[1].group, 'standalone');
    });

    test('parses compose labels without a runtime prefix', () {
      const out =
          'abc123\tweb\tnginx:1.25\tUp 3 hours\t80/tcp\tmyproj\tweb\t/opt/app\tcompose.yml,compose.prod.yml\t2026-05-01 00:00:00 +0000 UTC';
      final container = parseDockerPs(out).single;
      expect(container.group, 'myproj');
      expect(container.composeService, 'web');
      expect(container.composeWorkingDir, '/opt/app');
      expect(container.composeConfigFiles, 'compose.yml,compose.prod.yml');
      expect(container.runtime, 'docker', reason: 'unprefixed output defaults to docker');
    });

    test('recognises paused and restarting states', () {
      // A paused container reports e.g. "Up 3 hours (Paused)" — "Up" must not win over "Paused".
      const out =
          'a\tone\timg\tUp 3 hours (Paused)\t\t\t\t\t\t\n'
          'b\ttwo\timg\tRestarting (1) 5 seconds ago\t\t\t\t\t\t';
      final containers = parseDockerPs(out);
      expect(containers[0].status, 'paused');
      expect(containers[1].status, 'restarting');
    });

    test('a <no value> label becomes empty, not the literal text', () {
      const out = 'a\tone\timg\tUp\t80/tcp\t<no value>\t<no value>\t<no value>\t<no value>\t';
      final c = parseDockerPs(out).single;
      expect(c.group, 'standalone');
      expect(c.composeService, isEmpty);
      expect(c.composeWorkingDir, isEmpty);
    });

    test('SSH error text and short rows are skipped', () {
      expect(parseDockerPs('SSH Error: connection refused'), isEmpty);
      expect(parseDockerPs('too\tfew\tcells'), isEmpty);
    });

    test('an empty ports cell renders as an em dash', () {
      const out = 'a\tone\timg\tUp\t\tproj\t\t\t\t';
      expect(parseDockerPs(out).single.ports, '—');
    });
  });

  test('parseDockerRestartCounts keys by runtime when prefixed', () {
    final counts = parseDockerRestartCounts(
      'podman\tabc1234567890\t2\nabc1234567890\t2\ndef4567890000\t0',
    );
    expect(counts['podman:abc123456789'], 2);
    expect(counts['abc123456789'], 2);
    expect(counts['def456789000'], 0);
  });

  test('container resources carry their runtime prefix', () {
    final images = parseDockerImages(
      'podman\tsha256:abc1234567890\tnginx\tlatest\t187MB\t2 days ago',
    );
    expect(images.single.runtime, 'podman');
    expect(images.single.id, 'abc123456789', reason: 'sha256: prefix stripped, then 12 chars');

    final volumes = parseDockerVolumes(
      'podman\tpgdata\tlocal\t/var/lib/containers/storage/volumes/pgdata\t1GB\t1',
    );
    expect(volumes.single.runtime, 'podman');
    expect(volumes.single.inUse, isTrue);

    final networks = parseDockerNetworks('podman\tnet1234567890\tpodman\tbridge');
    expect(networks.single.runtime, 'podman');
  });

  test('a volume with no links is not in use', () {
    final volumes = parseDockerVolumes('pgdata\tlocal\t/var/lib/docker/volumes/pgdata\t1GB\t0');
    expect(volumes.single.inUse, isFalse);
  });

  group('parseMetrics — Linux', () {
    test('parses a GNU top / free / df probe', () {
      const out =
          '@CPU\n'
          '%Cpu(s):  3.4 us,  1.0 sy,  0.0 ni, 95.6 id,  0.0 wa\n'
          '@MEM\n'
          'Mem:  8000000000 2000000000 1000000000 0 5000000000 6000000000\n'
          '@DISK\n'
          '/dev/sda1 100000000000 18000000000 82000000000 18% /\n'
          '@LOAD\n'
          '0.08 0.11 0.09 2/297 1234\n'
          '@UP\n'
          '123456.78 100000.0\n'
          '@PROC\n'
          '297';
      final m = parseMetrics(out);
      expect(m.cpuPercent, closeTo(4.4, 0.05)); // 100 - 95.6
      expect(m.memTotalBytes, 8000000000);
      expect(m.memUsedBytes, 2000000000, reason: 'total - available, not the "used" column');
      expect(m.diskTotalBytes, 100000000000);
      expect(m.diskUsedBytes, 18000000000);
      expect(m.load1, closeTo(0.08, 0.001));
      expect(m.uptimeSeconds, 123456);
      expect(m.procCount, 297);
      expect(m.diskPercent, inInclusiveRange(17, 19));
      expect(m.os, 'Linux');
      expect(m.platforms, contains('linux'));
    });

    test('falls back to BusyBox top and /proc/meminfo', () {
      // BusyBox `top` uses "CPU: ... 98% idle" (no GNU "id"), and `free -b` may be absent so the
      // MEM section is empty — parseMetrics must fall back to /proc/meminfo (kB) rather than
      // silently reporting 0% memory.
      const out =
          '@CPU\n'
          'CPU:   1% usr   0% sys   0% nic  98% idle   0% io   0% irq   0% sirq\n'
          '@MEM\n'
          '@MEMINFO\n'
          'MemTotal:        2000000 kB\n'
          'MemFree:          500000 kB\n'
          'MemAvailable:    1600000 kB\n'
          '@DISK\n'
          '/dev/sda1 100000000000 18000000000 82000000000 18% /\n'
          '@LOAD\n'
          '0.10 0.20 0.30 1/100 555\n'
          '@UP\n'
          '5000.00 4000.0\n'
          '@PROC\n'
          '100';
      final m = parseMetrics(out);
      expect(m.cpuPercent, closeTo(2, 0.05)); // 100 - 98
      expect(m.memTotalBytes, 2000000 * 1024);
      expect(m.memUsedBytes, 400000 * 1024); // (total - available) * 1024
    });

    test('a KB1024 marker scales the BusyBox df fallback', () {
      const out = '@DISK\nKB1024 /dev/sda1 100000 18000 82000 18% /';
      final m = parseMetrics(out);
      expect(m.diskTotalBytes, 100000 * 1024);
      expect(m.diskUsedBytes, 18000 * 1024);
    });

    test('CPU temperature takes the hottest zone and converts millidegrees', () {
      const out = '@TEMP\n41000\n52000\n38000';
      expect(parseMetrics(out).cpuTempC, closeTo(52, 0.001));
    });

    test('a host with no thermal sensor reports null, not zero', () {
      expect(parseMetrics('@TEMP\n').cpuTempC, isNull);
      expect(parseMetrics('@TEMP\n0').cpuTempC, isNull);
    });

    test('the distro pretty-name wins over bare "Linux"', () {
      expect(parseMetrics('@DISTRO\nRaspberry Pi OS').os, 'Raspberry Pi OS');
      expect(parseMetrics('@DISTRO\n').os, 'Linux');
    });

    test('detected platforms always include linux', () {
      final m = parseMetrics('@PLATFORM\nproxmox\ndocker');
      expect(m.platforms, {'proxmox', 'docker', 'linux'});
    });

    test('SMART health is matched to a mount by whole-disk device', () {
      const out =
          '@DISKS\n'
          '/dev/sda1 100000000000 40000000000 60000000000 40% /\n'
          '/dev/nvme0n1p2 500000000000 100000000000 400000000000 20% /data\n'
          '@SMART\n'
          'sda\tPASSED\n'
          'nvme0n1\tFAILED';
      final disks = parseMetrics(out).disks;
      expect(disks.firstWhere((d) => d.mount == '/').health, 'PASSED');
      expect(
        disks.firstWhere((d) => d.mount == '/data').health,
        'FAILED',
        reason: 'the p2 partition suffix must be stripped to reach nvme0n1',
      );
    });

    test('proc count falls back to the LOAD section when @PROC is absent', () {
      final m = parseMetrics('@LOAD\n0.08 0.11 0.09 2/297 1234');
      expect(m.procCount, 297);
    });
  });

  test('parseMetrics — Windows populates cpu, mem, disk, uptime and procs', () {
    const out =
        '@OS\nWindows\n@WINCPU\n23\n@WINMEM\n8589934592 4294967296\n'
        '@WINDISK\nC: 107374182400 53687091200\n@WINUP\n3600\n@WINPROC\n140';
    final m = parseMetrics(out);
    expect(m.os, 'Windows');
    expect(m.cpuPercent.toInt(), 23);
    expect(m.memTotalBytes, 8589934592);
    expect(m.memUsedBytes, 4294967296);
    expect(m.disks, hasLength(1));
    expect(m.uptimeSeconds, 3600);
    expect(m.procCount, 140);
    expect(m.platforms, {'windows'});
  });

  test('parseMetrics — Darwin derives uptime from boot time and now', () {
    const out =
        '@OS\nDarwin\n@MEMSIZE\n17179869184\n'
        '@VMSTAT\nMach Virtual Memory Statistics: (page size of 4096 bytes)\n'
        'Pages free:                          100000.\n'
        'Pages inactive:                      100000.\n'
        'Pages speculative:                    50000.\n'
        '@LOADAVG\n{ 1.50 1.20 1.10 }\n'
        '@BOOT\n{ sec = 1000000, usec = 0 }\n'
        '@NOW\n1003600';
    final m = parseMetrics(out);
    expect(m.os, 'Darwin');
    expect(m.memTotalBytes, 17179869184);
    expect(m.uptimeSeconds, 3600);
    expect(m.load1, closeTo(1.5, 0.001));
    expect(m.platforms, {'darwin'});
  });

  group('parseDisks', () {
    test('filters pseudo filesystems and keeps real mounts', () {
      const df =
          '/dev/sda1 100000000000 40000000000 60000000000 40% /\n'
          'tmpfs 8000000000 0 8000000000 0% /dev/shm\n'
          '/dev/sdb1 500000000000 100000000000 400000000000 20% /data\n'
          'overlay 100000000000 50000000000 50000000000 50% /var/lib/docker/overlay2/x';
      final disks = parseDisks(df);
      final mounts = disks.map((d) => d.mount).toSet();
      expect(mounts, contains('/'));
      expect(mounts, contains('/data'));
      expect(mounts, isNot(contains('/dev/shm')), reason: 'pseudo fs and under /dev');
      expect(disks.where((d) => d.filesystem == 'overlay'), isEmpty);

      final root = disks.firstWhere((d) => d.mount == '/');
      expect(root.totalBytes, 100000000000);
      expect(root.percent.toInt(), 40);
    });

    test('a mount path containing spaces is preserved', () {
      const df = '/dev/sdc1 1000 500 500 50% /mnt/my backup';
      expect(parseDisks(df).single.mount, '/mnt/my backup');
    });

    test('duplicate mounts keep the first occurrence', () {
      const df = '/dev/sda1 1000 100 900 10% /\n/dev/sdb1 2000 200 1800 10% /';
      final disks = parseDisks(df);
      expect(disks, hasLength(1));
      expect(disks.single.filesystem, '/dev/sda1');
    });

    test('blockBytes scales BSD df -k output', () {
      const df = '/dev/ada0p2 1000 400 600 40% /';
      expect(parseDisks(df, blockBytes: 1024).single.totalBytes, 1000 * 1024);
    });

    test('zero-sized and malformed rows are skipped', () {
      expect(parseDisks('/dev/sda1 0 0 0 0% /'), isEmpty);
      expect(parseDisks('not enough columns'), isEmpty);
    });
  });

  group('/proc parsing', () {
    test('parseDiskIo covers whole disks only', () {
      const ds =
          '8 0 sda 1000 0 2000 0 500 0 4000 0 0 0 0\n'
          '8 1 sda1 100 0 200 0 50 0 400 0 0 0 0\n'
          '259 0 nvme0n1 10 0 80 0 5 0 16 0 0 0 0';
      final io = parseDiskIo(ds);
      expect(io.keys, containsAll(<String>['sda', 'nvme0n1']));
      expect(io.containsKey('sda1'), isFalse, reason: 'partitions excluded');
      expect(io['sda']!.readBytes, 2000 * 512);
      expect(io['sda']!.writeBytes, 4000 * 512);
    });

    test('parseProcStat extracts idle and total per core', () {
      const stat =
          'cpu  100 0 100 700 100 0 0 0 0 0\n'
          'cpu0 50 0 50 350 50 0 0 0 0 0\n'
          'cpu1 50 0 50 350 50 0 0 0 0 0';
      final m = parseProcStat(stat);
      expect(m.keys, containsAll(<String>['cpu', 'cpu0', 'cpu1']));
      // idle = idle(700) + iowait(100) = 800; total = sum of all = 1000.
      expect(m['cpu']!.$1, 800);
      expect(m['cpu']!.$2, 1000);
    });

    test('aggregate CPU matches the same delta model as per-core', () {
      final prev = parseProcStat(
        'cpu  100 0 0 900 0 0 0 0\ncpu0 50 0 0 450 0 0 0 0\ncpu1 50 0 0 450 0 0 0 0',
      );
      final cur = parseProcStat(
        'cpu  160 0 0 940 0 0 0 0\ncpu0 80 0 0 470 0 0 0 0\ncpu1 80 0 0 470 0 0 0 0',
      );

      expect(computeCpuUsageDelta(prev, cur, 'cpu'), closeTo(60, 0.001));
      final perCore = computePerCoreCpuDeltas(prev, cur);
      expect(perCore, hasLength(2));
      expect(perCore[0], closeTo(60, 0.001));
      expect(perCore[1], closeTo(60, 0.001));
    });

    test('the first sample has no baseline, so yields null / empty', () {
      final cur = parseProcStat('cpu  100 0 0 900 0 0 0 0');
      expect(computeCpuUsageDelta(null, cur, 'cpu'), isNull);
      expect(computePerCoreCpuDeltas(null, cur), isEmpty);
    });

    test('per-core deltas sort numerically, not lexically', () {
      var stat = StringBuffer('cpu 0 0 0 0 0\n');
      for (var i = 0; i < 12; i++) {
        stat.writeln('cpu$i 0 0 0 0 0');
      }
      final prev = parseProcStat(stat.toString());
      expect(
        computePerCoreCpuDeltas(prev, prev),
        hasLength(12),
        reason: 'cpu10 must not sort between cpu1 and cpu2 and drop cores',
      );
    });

    test('parseNetDev skips loopback and reads rx/tx', () {
      const dev =
          'Inter-|   Receive                                |  Transmit\n'
          ' face |bytes    packets errs drop fifo frame compressed multicast|bytes    packets\n'
          '    lo:  1000      10    0    0    0     0          0         0    1000      10\n'
          '  eth0: 5000000   5000  0    0    0     0          0         0   2000000    3000';
      final m = parseNetDev(dev);
      expect(m.containsKey('lo'), isFalse);
      expect(m['eth0']!.$1, 5000000);
      expect(m['eth0']!.$2, 2000000);
    });
  });

  /// The wire format keys on the **source index**, not the basename — tabs and newlines are legal
  /// in filenames and would otherwise corrupt the line protocol. These tests therefore feed indices
  /// and the source list they address, which is what `compareForConflicts` really emits.
  group('parseTransferConflicts', () {
    const sources = [
      '/src/same.txt',
      '/src/diff.txt',
      '/src/folder',
      '/src/mystery.txt',
    ];

    test('classifies verdicts and defaults the safe way round', () {
      const out =
          '0\tIDENTICAL\t100\t100\t1000\t2000\n'
          '1\tDIFFERENT\t100\t200\t1000\t2000\n'
          '2\tDIR\t0\t0\t1000\t2000\n'
          '3\tWHO_KNOWS\t100\t100\t1000\t2000';
      final conflicts = parseTransferConflicts(out, sources);
      expect(conflicts, hasLength(4));

      // The index is resolved back to the basename the user will recognise.
      expect(conflicts.map((c) => c.name), [
        'same.txt',
        'diff.txt',
        'folder',
        'mystery.txt',
      ]);

      expect(conflicts[0].verdict, ConflictVerdict.identical);
      expect(
        conflicts[0].action,
        ConflictAction.overwrite,
        reason: 'overwriting proven-identical bytes destroys nothing',
      );

      expect(conflicts[1].verdict, ConflictVerdict.different);
      expect(conflicts[1].action, ConflictAction.keepBoth);

      expect(conflicts[2].verdict, ConflictVerdict.directory);
      expect(conflicts[2].action, ConflictAction.keepBoth);

      expect(
        conflicts[3].verdict,
        ConflictVerdict.unknown,
        reason: 'an unclassifiable clash must never be treated as identical',
      );
      expect(conflicts[3].action, ConflictAction.keepBoth);
    });

    test('sizes and mtimes are carried through', () {
      final c = parseTransferConflicts(
        '0\tDIFFERENT\t10\t20\t111\t222',
        const ['/src/a'],
      ).single;
      expect(c.sourceSize, 10);
      expect(c.destSize, 20);
      expect(c.sourceMtimeSeconds, 111);
      expect(c.destMtimeSeconds, 222);
    });

    test('short, unindexed or out-of-range rows are dropped', () {
      const one = ['/src/a'];
      expect(parseTransferConflicts('0\tIDENTICAL\t1\t1', one), isEmpty);
      expect(parseTransferConflicts('\tIDENTICAL\t1\t1\t1\t1', one), isEmpty);
      expect(parseTransferConflicts('no tabs here', one), isEmpty);
      // An index nothing addresses is dropped, never guessed at.
      expect(parseTransferConflicts('7\tIDENTICAL\t1\t1\t1\t1', one), isEmpty);
      expect(parseTransferConflicts('-1\tIDENTICAL\t1\t1\t1\t1', one), isEmpty);
    });

    test('a filename containing a tab is reported whole', () {
      // It arrives via the source list, so the tab never reaches the line protocol.
      final c = parseTransferConflicts(
        '0\tDIFFERENT\t1\t2\t3\t4',
        const ['/src/we\tird.txt'],
      ).single;
      expect(c.name, 'we\tird.txt');
    });
  });

  group('composeStackWorkingDir', () {
    test('prefers the label, then the first config file parent', () {
      expect(composeStackWorkingDir('/srv/app', '/elsewhere/docker-compose.yml'), '/srv/app');
      // podman-compose case: config_files label set, working_dir absent.
      expect(
        composeStackWorkingDir(
          '',
          '/srv/stacks/app/docker-compose.yml,/srv/stacks/app/override.yml',
        ),
        '/srv/stacks/app',
      );
      // A relative config file gives no usable directory.
      expect(composeStackWorkingDir('', 'relative/compose.yml'), '');
      expect(composeStackWorkingDir('', ''), '');
    });

    test('a config file at the filesystem root yields /', () {
      expect(composeStackWorkingDir('', '/compose.yml'), '/');
    });
  });

  test('humanBytes formats readably and locale-independently', () {
    expect(humanBytes(0), '0 B');
    expect(humanBytes(-5), '0 B');
    expect(humanBytes(512), '512 B');
    expect(humanBytes(1024), '1.0 KB');
    expect(humanBytes(1024 * 1024 * 1024), '1.0 GB');
    expect(humanBytes(1536), '1.5 KB', reason: 'decimal separator is always "."');
  });

  test('parseSmart maps device to health', () {
    expect(parseSmart('sda\tPASSED\nsdb\tFAILED\nbroken-line'), {'sda': 'PASSED', 'sdb': 'FAILED'});
  });
}
