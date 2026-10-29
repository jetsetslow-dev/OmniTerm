// Per-process disk and GPU use from what the Linux and Windows process commands append. Ported
// from app/src/test/java/com/jetsetslow/omniterm/ProcessUsageParserTest.kt.

import 'package:flutter_test/flutter_test.dart';
import 'package:omniterm/data/host_tools.dart';
import 'package:omniterm/data/kotlin_strings.dart';
import 'package:omniterm/data/remote_commands.dart';
import 'package:omniterm/data/remote_models.dart';
import 'package:omniterm/data/remote_parsers.dart';
import 'package:omniterm/ui/view_model/monitor_view_model.dart';

const _ps =
    'PID USER %CPU %MEM VSZ ELAPSED STAT COMMAND\n'
    '101 root 12.0 1.5 2048 01:00 S rsync\n'
    '202 alice 40.0 9.0 4096 02:00 R blender\n'
    '303 root 0.5 0.1 1024 03:00 S sshd';

// 2 s between samples: rsync read 4 MiB and wrote 2 MiB; blender's render engine was busy 1.5 s
// through one client that sits behind two descriptors; sshd's io was unreadable.
const _output =
    '$_ps\n'
    '$processSampleMarker 1000000000\n'
    '/proc/101/io:read_bytes: 1000\n'
    '/proc/101/io:write_bytes: 500\n'
    '/proc/202/io:read_bytes: 0\n'
    '/proc/202/io:write_bytes: 0\n'
    '/proc/202/fdinfo/7:drm-pdev:\t0000:03:00.0\n'
    '/proc/202/fdinfo/7:drm-client-id:\t42\n'
    '/proc/202/fdinfo/7:drm-engine-gfx:\t1000000000 ns\n'
    '/proc/202/fdinfo/7:drm-engine-dec:\t0 ns\n'
    '/proc/202/fdinfo/9:drm-pdev:\t0000:03:00.0\n'
    '/proc/202/fdinfo/9:drm-client-id:\t42\n'
    '/proc/202/fdinfo/9:drm-engine-gfx:\t1000000000 ns\n'
    '$processSampleMarker 3000000000\n'
    '/proc/101/io:read_bytes: 4195304\n'
    '/proc/101/io:write_bytes: 2097652\n'
    '/proc/202/io:read_bytes: 0\n'
    '/proc/202/io:write_bytes: 0\n'
    '/proc/202/fdinfo/7:drm-pdev:\t0000:03:00.0\n'
    '/proc/202/fdinfo/7:drm-client-id:\t42\n'
    '/proc/202/fdinfo/7:drm-engine-gfx:\t2500000000 ns\n'
    '/proc/202/fdinfo/7:drm-engine-dec:\t0 ns\n'
    '/proc/202/fdinfo/9:drm-pdev:\t0000:03:00.0\n'
    '/proc/202/fdinfo/9:drm-client-id:\t42\n'
    '/proc/202/fdinfo/9:drm-engine-gfx:\t2500000000 ns';

// What processesWindows prints, CRLF and all: the list, then the I/O rates the counters give per
// second, then each process's busiest GPU engine.
final _windows =
    '${['4120 NA 35 0 512000 00:00:00 R blender', '880 NA 2 0 20480 00:00:00 R svchost', processRatesMarker, '4120 1048576 2048', '880 0 0', processGpuMarker, '4120 87', '1999 3'].join('\r\n')}\r\n';

DiskRate _rate(int read, int write) =>
    DiskRate(readBytesPerSecond: read, writeBytesPerSecond: write);

void main() {
  test(
    'an nvidia driver without nvidia-smi is named as the tool to install, not as a gpu source',
    () {
      final usage = parseProcessUsage(
        '$_ps\n'
        '$processSampleMarker 1000000000\n'
        '/proc/101/io:read_bytes: 1000\n'
        '/proc/101/io:write_bytes: 500\n'
        '$processSampleMarker 2000000000\n'
        '/proc/101/io:read_bytes: 2000\n'
        '/proc/101/io:write_bytes: 500\n'
        '$processNvidiaSmiMissingMarker',
      );
      expect(usage.missingTool, HostTool.nvidiaSmi);
      expect(usage.gpuReported, isFalse, reason: 'no GPU use was reported, so no GPU column');
      expect(usage.disk[101], _rate(1000, 0), reason: 'the samples before the marker still count');
      expect(
        processNvidiaSmiMissingMarker.startsWith(processNvidiaMarker),
        isFalse,
        reason:
            "the parser finds pmon output by its marker's prefix, so this one must not share it",
      );
      expect(parseProcessUsage(_output).missingTool, isNull);
      expect(
        processesLinux,
        contains(
          "elif [ -e /proc/driver/nvidia/version ] && [ -e /dev/nvidiactl ]; then echo "
          "'$processNvidiaSmiMissingMarker'",
        ),
      );
    },
  );

  test('disk rates are the difference over the time between samples', () {
    final usage = parseProcessUsage(_output);
    expect(usage.disk[101], _rate(2097152, 1048576));
    expect(usage.disk[202], _rate(0, 0));
    expect(usage.disk[303], isNull, reason: 'Unreadable counters are unknown, not zero');
  });

  test('gpu use is the busiest engine with a shared client counted once', () {
    final usage = parseProcessUsage(_output);
    expect(usage.gpuReported, isTrue);
    // 1.5 s of gfx time over 2 s; counting both descriptors would make it 150%.
    expect(usage.gpu[202], closeTo(75, 0.01));
    expect(usage.gpu[101], isNull);
  });

  test('an engine class with several engines is divided by their number', () {
    final twoEngines = _output.replaceFirst(
      '/proc/202/fdinfo/7:drm-engine-gfx:\t2500000000 ns',
      '/proc/202/fdinfo/7:drm-engine-gfx:\t2500000000 ns\n'
          '/proc/202/fdinfo/7:drm-engine-capacity-gfx:\t2',
    );
    expect(parseProcessUsage(twoEngines).gpu[202], closeTo(37.5, 0.01));
  });

  test("intel xe cycles are a share of the gpu's total cycles", () {
    const xe =
        '$_ps\n'
        '$processSampleMarker 1000000000\n'
        '/proc/202/fdinfo/5:drm-pdev:\t0000:00:02.0\n'
        '/proc/202/fdinfo/5:drm-client-id:\t7\n'
        '/proc/202/fdinfo/5:drm-cycles-rcs:\t1000\n'
        '/proc/202/fdinfo/5:drm-total-cycles-rcs:\t50000\n'
        '/proc/202/fdinfo/5:drm-cycles-vcs:\t0\n'
        '/proc/202/fdinfo/5:drm-total-cycles-vcs:\t50000\n'
        '$processSampleMarker 2000000000\n'
        '/proc/202/fdinfo/5:drm-pdev:\t0000:00:02.0\n'
        '/proc/202/fdinfo/5:drm-client-id:\t7\n'
        '/proc/202/fdinfo/5:drm-cycles-rcs:\t21000\n'
        '/proc/202/fdinfo/5:drm-total-cycles-rcs:\t130000\n'
        '/proc/202/fdinfo/5:drm-cycles-vcs:\t0\n'
        '/proc/202/fdinfo/5:drm-total-cycles-vcs:\t130000';
    final usage = parseProcessUsage(xe);
    expect(usage.gpuReported, isTrue);
    // 20 000 of 80 000 cycles.
    expect(usage.gpu[202], closeTo(25, 0.01));
  });

  test('a clock without nanoseconds counts the samples a second apart', () {
    // BusyBox date prints "%N" literally.
    final busybox = _output
        .replaceFirst('$processSampleMarker 1000000000', '$processSampleMarker 1%N')
        .replaceFirst('$processSampleMarker 3000000000', '$processSampleMarker 3%N');
    expect(parseProcessUsage(busybox).disk[101]!.readBytesPerSecond, 4194304);
  });

  test('nvidia pmon reports sm use and marks the gpu as present', () {
    const nvidia =
        '$_ps\n'
        '$processNvidiaMarker\n'
        '# gpu         pid   type     sm    mem    enc    dec    command\n'
        '# Idx           #    C/G      %      %      %      %    name\n'
        '    0        202     C     64     20      -      -    blender\n'
        '    0          -     -      -      -      -      -    -';
    final usage = parseProcessUsage(nvidia);
    expect(usage.gpuReported, isTrue);
    expect(usage.gpu[202], closeTo(64, 0.01));
  });

  test('nvidia-smi without a working driver does not add a gpu column', () {
    final usage = parseProcessUsage('$_ps\n$processNvidiaMarker\n');
    expect(usage.gpuReported, isFalse);
  });

  test('the process list ignores the samples after it', () {
    const nvidia = '$_output\n$processNvidiaMarker\n    0  202  C  64  20  -  -  blender';
    expect(parseProcesses(nvidia).map((p) => p.pid), [101, 202, 303]);
  });

  test('windows sends its own rates and busiest gpu engine', () {
    final usage = parseProcessUsage(_windows);
    expect(usage.disk[4120], _rate(1048576, 2048));
    expect(usage.disk[880], _rate(0, 0));
    expect(usage.gpuReported, isTrue);
    expect(usage.gpu[4120], closeTo(87, 0.01));
    expect(usage.gpu[880], isNull, reason: 'no GPU engine of its own');
    expect(parseProcesses(_windows).map((p) => p.pid), [4120, 880]);
  });

  test('windows without gpu counters shows no gpu column', () {
    final older = _windows.substringBefore(processGpuMarker);
    final usage = parseProcessUsage(older);
    expect(usage.gpuReported, isFalse);
    expect(usage.disk[4120], _rate(1048576, 2048));
  });

  test('sorting by disk or gpu puts processes without a reading last', () {
    SimProcess proc(int pid, {DiskRate? disk, double? gpu}) => SimProcess(
      pid: pid,
      name: '$pid',
      owner: 'u',
      cpu: 1,
      mem: 1,
      state: 'S',
      vms: '1K',
      disk: disk,
      gpu: gpu,
    );
    final procs = [
      proc(1),
      proc(2, disk: _rate(10, 0), gpu: 5),
      proc(3, disk: _rate(0, 50), gpu: 0),
    ];
    expect(MonitorViewModel.sortProcesses(procs, ProcessSort.disk).map((p) => p.pid), [3, 2, 1]);
    expect(MonitorViewModel.sortProcesses(procs, ProcessSort.gpu).map((p) => p.pid), [2, 3, 1]);
  });

  test('sorting keeps the host order among equal readings, as Kotlin does', () {
    final procs = [
      for (var pid = 1; pid <= 40; pid++)
        SimProcess(pid: pid, name: '$pid', owner: 'u', cpu: 1, mem: 1, state: 'S', vms: '1K'),
    ];
    expect(MonitorViewModel.sortProcesses(procs, ProcessSort.mem).map((p) => p.pid), [
      for (var pid = 1; pid <= 40; pid++) pid,
    ]);
  });
}
