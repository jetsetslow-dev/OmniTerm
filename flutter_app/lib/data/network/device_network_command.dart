import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// A running, trusted system-network command.
abstract interface class DeviceNetworkCommand {
  Stream<String> get lines;
  Future<int> get exitCode;
  void stop();
}

/// Starts the device-side ICMP tools used by the Kotlin app.
///
/// Kept behind an interface so host tests never execute the workstation's own binaries. The IO
/// implementation searches only fixed system paths; a hostname is always an argument and can
/// never influence executable lookup.
abstract interface class DeviceNetworkCommandRunner {
  Future<DeviceNetworkCommand?> startPing(String target, {required int count, int? ttl});

  Future<DeviceNetworkCommand?> startTraceroute(String target);
}

class IoDeviceNetworkCommandRunner implements DeviceNetworkCommandRunner {
  const IoDeviceNetworkCommandRunner();

  static List<String> get _pingBinaries {
    if (Platform.isAndroid) return const ['/system/bin/ping'];
    if (Platform.isMacOS) return const ['/sbin/ping'];
    if (Platform.isLinux) return const ['/bin/ping', '/usr/bin/ping'];
    // iOS does not expose a sandbox-safe ping executable and raw ICMP needs an entitlement/root.
    return const [];
  }

  static List<String> get _tracerouteBinaries {
    if (Platform.isAndroid) {
      return const ['/system/bin/traceroute', '/system/xbin/traceroute'];
    }
    if (Platform.isMacOS) return const ['/usr/sbin/traceroute'];
    if (Platform.isLinux) {
      return const ['/usr/bin/traceroute', '/bin/traceroute'];
    }
    return const [];
  }

  @override
  Future<DeviceNetworkCommand?> startPing(String target, {required int count, int? ttl}) async {
    final arguments = <String>[
      if (count > 0) ...['-c', count.toString()],
      '-W',
      Platform.isMacOS ? '3000' : '3',
      if (ttl != null) ...[Platform.isMacOS ? '-m' : '-t', ttl.toString()],
      target,
    ];
    return _startFirst(_pingBinaries, arguments);
  }

  @override
  Future<DeviceNetworkCommand?> startTraceroute(String target) async {
    for (final binary in _tracerouteBinaries) {
      for (final arguments in [
        ['-n', '-m', '30', target],
        [target],
      ]) {
        final command = await _start(binary, arguments);
        if (command != null) return command;
      }
    }
    return null;
  }

  Future<DeviceNetworkCommand?> _startFirst(List<String> binaries, List<String> arguments) async {
    for (final binary in binaries) {
      final command = await _start(binary, arguments);
      if (command != null) return command;
    }
    return null;
  }

  Future<DeviceNetworkCommand?> _start(String executable, List<String> arguments) async {
    try {
      return _IoDeviceNetworkCommand(await Process.start(executable, arguments, runInShell: false));
    } on ProcessException {
      return null;
    } on UnsupportedError {
      return null;
    }
  }
}

class _IoDeviceNetworkCommand implements DeviceNetworkCommand {
  _IoDeviceNetworkCommand(this._process) : lines = _mergedLines(_process);

  final Process _process;

  @override
  final Stream<String> lines;

  @override
  Future<int> get exitCode => _process.exitCode;

  @override
  void stop() => _process.kill();

  static Stream<String> _mergedLines(Process process) {
    final controller = StreamController<String>();
    var remaining = 2;
    void finished() {
      remaining--;
      if (remaining == 0 && !controller.isClosed) unawaited(controller.close());
    }

    void attach(Stream<List<int>> bytes) {
      bytes
          .transform(systemEncoding.decoder)
          .transform(const LineSplitter())
          .listen(
            controller.add,
            onError: controller.addError,
            onDone: finished,
            cancelOnError: false,
          );
    }

    attach(process.stdout);
    attach(process.stderr);
    return controller.stream;
  }
}

/// The same conservative argument alphabet as the Kotlin process boundary.
bool isValidNetworkCommandTarget(String value) =>
    value.isNotEmpty &&
    value.runes.every((rune) {
      final char = String.fromCharCode(rune);
      return RegExp(r'[A-Za-z0-9.\-:%_\[\]]').hasMatch(char);
    });
