import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omniterm/data/app_database.dart';
import 'package:omniterm/data/app_repository.dart';
import 'package:omniterm/data/network/network_probe.dart';
import 'package:omniterm/data/network/device_network_command.dart';
import 'package:omniterm/data/network/speed_test_client.dart';
import 'package:omniterm/domain/network_tools.dart';
import 'package:omniterm/platform/secret_store.dart';
import 'package:omniterm/ui/view_model/app_state.dart';
import 'package:omniterm/data/network/whois_client.dart';
import 'package:omniterm/ui/view_model/network_view_model.dart';

import 'support/fake_secure_storage.dart';

/// A network that exists only in the test. Nothing here touches a real socket, so the suite passes
/// identically on a laptop in a café and on a machine with a full homelab behind it.
class FakeProbe implements NetworkProbe {
  FakeProbe({
    this.open = const {},
    this.names = const {},
    this.mdnsNames = const {},
    this.netbiosNames = const {},
    this.local = '192.168.1.42',
  });

  /// `host:port` pairs that answer.
  final Set<String> open;

  /// Reverse-lookup answers.
  final Map<String, String> names;
  final Map<String, String> mdnsNames;
  final Map<String, String> netbiosNames;

  final String? local;

  final List<(String, int)> pinged = [];
  final List<(Uint8List, String, int)> sentPackets = [];
  final List<String> resolversTried = [];

  /// Resolver responses, by resolver address. A missing entry throws, simulating unreachable.
  Map<String, Uint8List> dnsResponses = {};

  @override
  Future<Duration?> tcpPing(
    String host,
    int port, {
    Duration timeout = const Duration(seconds: 2),
  }) async {
    pinged.add((host, port));
    return open.contains('$host:$port') ? const Duration(milliseconds: 12) : null;
  }

  @override
  Future<void> sendMagicPacket(Uint8List packet, String broadcast, int port) async {
    sentPackets.add((packet, broadcast, port));
  }

  @override
  Future<Uint8List> resolve(
    Uint8List query, {
    required String resolver,
    Duration timeout = const Duration(seconds: 3),
  }) async {
    resolversTried.add(resolver);
    final response = dnsResponses[resolver];
    if (response == null) throw const SocketFailure();
    // Echo the query's transaction id, as a real resolver does.
    final out = Uint8List.fromList(response);
    out[0] = query[0];
    out[1] = query[1];
    return out;
  }

  @override
  Future<String?> reverseLookup(String address) async => names[address];

  @override
  Future<String?> mdnsReverseLookup(
    String address, {
    Duration timeout = const Duration(milliseconds: 900),
  }) async => mdnsNames[address];

  @override
  Future<String?> netbiosName(
    String address, {
    Duration timeout = const Duration(milliseconds: 900),
  }) async => netbiosNames[address];

  @override
  Future<String?> localAddress() async => local;
}

class SocketFailure implements Exception {
  const SocketFailure();

  @override
  String toString() => 'network unreachable';
}

class FakeDeviceCommand implements DeviceNetworkCommand {
  FakeDeviceCommand(this.output);

  final List<String> output;
  bool stopped = false;

  @override
  Stream<String> get lines => Stream.fromIterable(output);

  @override
  Future<int> get exitCode async => 0;

  @override
  void stop() => stopped = true;
}

class FakeDeviceCommands implements DeviceNetworkCommandRunner {
  FakeDeviceCommands({
    this.pingOutput = const [
      '64 bytes from 10.0.0.1: icmp_seq=1 ttl=64 time=12.0 ms',
      '--- 10.0.0.1 ping statistics ---',
      '1 packets transmitted, 1 received, 0% packet loss',
    ],
    this.tracerouteOutput,
    this.ttlOutput = const {},
    this.available = true,
  });

  final List<String> pingOutput;
  final List<String>? tracerouteOutput;
  final Map<int, List<String>> ttlOutput;
  final bool available;
  final List<(String, int, int?)> pings = [];

  @override
  Future<DeviceNetworkCommand?> startPing(String target, {required int count, int? ttl}) async {
    pings.add((target, count, ttl));
    if (!available) return null;
    return FakeDeviceCommand(ttl == null ? pingOutput : (ttlOutput[ttl] ?? const []));
  }

  @override
  Future<DeviceNetworkCommand?> startTraceroute(String target) async {
    final output = tracerouteOutput;
    return output == null ? null : FakeDeviceCommand(output);
  }
}

/// Builds a DNS response with one A record for `example.com`.
Uint8List aRecordResponse({List<int> address = const [93, 184, 216, 34]}) {
  final out = BytesBuilder()
    ..add([0x12, 0x34, 0x81, 0x80])
    ..add([0x00, 0x01])
    ..add([0x00, 0x01])
    ..add([0x00, 0x00])
    ..add([0x00, 0x00])
    ..add([7])
    ..add(utf8.encode('example'))
    ..add([3])
    ..add(utf8.encode('com'))
    ..add([0])
    ..add([0x00, 0x01])
    ..add([0x00, 0x01])
    ..add([0xC0, 0x0C])
    ..add([0x00, 0x01])
    ..add([0x00, 0x01])
    ..add([0x00, 0x00, 0x01, 0x2C])
    ..add([0x00, 0x04])
    ..add(address);
  return out.toBytes();
}

/// A response carrying an NXDOMAIN code.
Uint8List nxdomainResponse() {
  final out = BytesBuilder()
    ..add([0x12, 0x34, 0x81, 0x83])
    ..add([0x00, 0x00])
    ..add([0x00, 0x00])
    ..add([0x00, 0x00])
    ..add([0x00, 0x00]);
  return out.toBytes();
}

/// Answers WHOIS queries from a script, recording who was asked.
class FakeWhois implements WhoisClient {
  FakeWhois(this.replies);

  /// Server host to reply. A [WhoisException] value is thrown instead of returned.
  final Map<String, Object> replies;

  final List<(String server, String target)> asked = [];

  @override
  Future<String> query(String server, String target) async {
    asked.add((server, target));
    final reply = replies[server];
    if (reply is WhoisException) throw reply;
    return (reply as String?) ?? '';
  }
}

class FakeSpeedTest implements SpeedTestClient {
  FakeSpeedTest({this.failure});

  final Object? failure;
  String? requestedUrl;

  @override
  SpeedTestOperation download(
    String url, {
    required void Function(SpeedTestSample sample) onProgress,
    Duration maximumDuration = const Duration(seconds: 15),
  }) {
    requestedUrl = url;
    final created = _FakeSpeedOperation();
    scheduleMicrotask(() {
      onProgress(const SpeedTestSample(bytes: 1048576, mbps: 8.4));
      if (failure != null) {
        created.completeError(failure!);
      } else {
        created.complete(
          const SpeedTestResult(bytes: 2097152, mbps: 16.8, latency: Duration(milliseconds: 23)),
        );
      }
    });
    return created;
  }
}

class _FakeSpeedOperation implements SpeedTestOperation {
  final _completer = Completer<SpeedTestResult>();
  bool cancelled = false;

  @override
  Future<SpeedTestResult> get result => _completer.future;

  void complete(SpeedTestResult result) => _completer.complete(result);
  void completeError(Object error) => _completer.completeError(error);

  @override
  void cancel() {
    cancelled = true;
    if (!_completer.isCompleted) {
      _completer.completeError(StateError('cancelled'));
    }
  }
}

class _HoldingSpeedTest implements SpeedTestClient {
  final operation = _FakeSpeedOperation();

  @override
  SpeedTestOperation download(
    String url, {
    required void Function(SpeedTestSample sample) onProgress,
    Duration maximumDuration = const Duration(seconds: 15),
  }) => operation;
}

class _QueuedSpeedTest implements SpeedTestClient {
  final List<_FakeSpeedOperation> operations = [];

  @override
  SpeedTestOperation download(
    String url, {
    required void Function(SpeedTestSample sample) onProgress,
    Duration maximumDuration = const Duration(seconds: 15),
  }) {
    final operation = _FakeSpeedOperation();
    operations.add(operation);
    return operation;
  }
}

void main() {
  late AppDatabase db;
  late AppRepository repo;
  late AppState app;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    repo = AppRepository(db, SecretStore(storage: FakeSecureStorage(<String, String>{})));
    app = AppState(repo);
  });

  tearDown(() async {
    app.dispose();
    await db.close();
  });

  Future<NetworkViewModel> boot(
    FakeProbe probe, {
    WhoisClient? whois,
    SpeedTestClient? speedTest,
    DeviceNetworkCommandRunner? deviceCommands,
  }) async {
    await app.start();
    final vm = NetworkViewModel(
      app,
      probe: probe,
      whois: whois,
      speedTest: speedTest,
      deviceCommands: deviceCommands ?? FakeDeviceCommands(),
      arpReader: () async => const {},
    );
    await vm.start();
    await Future<void>.delayed(Duration.zero);
    return vm;
  }

  Future<void> settle() async {
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
  }

  group('host scan', () {
    test('the subnet is guessed from the device address', () async {
      // Typing a /24 on a phone is tedious, and on a home network it is almost always this one.
      final vm = await boot(FakeProbe(local: '10.0.5.77'));
      expect(vm.subnetPrefix, '10.0.5');
      vm.dispose();
    });

    test('a user-set subnet is not overwritten by the guess', () async {
      final vm = await boot(FakeProbe(local: '10.0.5.77'));
      vm.subnetPrefix = '172.16.0';
      await vm.guessSubnet();
      expect(vm.subnetPrefix, '172.16.0');
      vm.dispose();
    });

    test('only hosts that answer are listed, with their open ports', () async {
      final probe = FakeProbe(
        open: {'192.168.1.5:22', '192.168.1.5:80', '192.168.1.9:443'},
        names: {'192.168.1.5': 'nas.local'},
      );
      final vm = await boot(probe);
      vm.subnetPrefix = '192.168.1';
      await vm.scanSubnet();

      expect(vm.scanResults.map((h) => h.address), ['192.168.1.5', '192.168.1.9']);
      expect(vm.scanResults.first.openPorts, [22, 80]);
      expect(vm.scanResults.first.hostname, 'nas.local');
      expect(vm.scanResults.last.hostname, isNull, reason: 'no PTR record is not a failure');
      vm.dispose();
    });

    test('mDNS then NetBIOS fill names when the router has no PTR records', () async {
      final probe = FakeProbe(
        open: {'192.168.1.5:22', '192.168.1.9:445'},
        mdnsNames: {'192.168.1.5': 'nas.local.'},
        netbiosNames: {'192.168.1.5': 'IGNORED', '192.168.1.9': 'OFFICE-NAS'},
      );
      final vm = await boot(probe);
      vm.subnetPrefix = '192.168.1';
      await vm.scanSubnet();

      expect(vm.scanResults.map((host) => host.hostname), ['nas.local', 'office-nas']);
      vm.dispose();
    });

    test('the sweep skips the network and broadcast addresses', () async {
      final probe = FakeProbe();
      final vm = await boot(probe);
      vm.subnetPrefix = '192.168.1';
      await vm.scanSubnet();

      final probed = probe.pinged.map((p) => p.$1).toSet();
      expect(probed, isNot(contains('192.168.1.0')));
      expect(probed, isNot(contains('192.168.1.255')));
      expect(probed, hasLength(254));
      vm.dispose();
    });

    test('results are ordered numerically, not lexically', () async {
      // .10 sorting before .9 reads as though addresses are missing.
      final probe = FakeProbe(open: {'192.168.1.9:22', '192.168.1.10:22', '192.168.1.100:22'});
      final vm = await boot(probe);
      vm.subnetPrefix = '192.168.1';
      await vm.scanSubnet();

      expect(vm.scanResults.map((h) => h.address), [
        '192.168.1.9',
        '192.168.1.10',
        '192.168.1.100',
      ]);
      vm.dispose();
    });

    test('a malformed subnet is refused before any probing', () async {
      final probe = FakeProbe();
      final vm = await boot(probe);
      vm.subnetPrefix = 'not a subnet';
      await vm.scanSubnet();

      expect(vm.error, contains('192.168.1'));
      expect(probe.pinged, isEmpty);
      vm.dispose();
    });
  });

  group('wake on LAN', () {
    test('a target is saved with a normalised MAC', () async {
      final vm = await boot(FakeProbe());
      expect(await vm.saveWolTarget(name: 'nas', macAddress: 'AA-BB-CC-DD-EE-FF'), isNull);
      await settle();
      expect(vm.wolTargets.single.macAddress, 'aa:bb:cc:dd:ee:ff');
      vm.dispose();
    });

    test('an unusable MAC is refused at save time', () async {
      // A saved target with a bad MAC looks fine in the list and silently does nothing forever.
      final vm = await boot(FakeProbe());
      expect(await vm.saveWolTarget(name: 'nas', macAddress: 'nope'), contains('MAC'));
      expect(await vm.saveWolTarget(name: '  ', macAddress: 'aa:bb:cc:dd:ee:ff'), contains('Name'));
      await settle();
      expect(vm.wolTargets, isEmpty);
      vm.dispose();
    });

    test('the broadcast address is derived from the host IP when not given', () async {
      final vm = await boot(FakeProbe());
      await vm.saveWolTarget(
        name: 'nas',
        macAddress: 'aa:bb:cc:dd:ee:ff',
        ipAddress: '192.168.4.20',
      );
      await settle();
      expect(vm.wolTargets.single.broadcastIp, '192.168.4.255');
      vm.dispose();
    });

    test('with no IP at all it falls back to the global broadcast', () async {
      final vm = await boot(FakeProbe());
      await vm.saveWolTarget(name: 'nas', macAddress: 'aa:bb:cc:dd:ee:ff');
      await settle();
      expect(vm.wolTargets.single.broadcastIp, '255.255.255.255');
      vm.dispose();
    });

    test('waking sends a correct magic packet to the broadcast address', () async {
      final probe = FakeProbe();
      final vm = await boot(probe);
      await vm.saveWolTarget(
        name: 'nas',
        macAddress: 'aa:bb:cc:dd:ee:ff',
        ipAddress: '192.168.4.20',
      );
      await settle();

      final message = await vm.wake(vm.wolTargets.single);

      final (packet, broadcast, port) = probe.sentPackets.single;
      expect(packet, magicPacketFor('aa:bb:cc:dd:ee:ff'));
      expect(broadcast, '192.168.4.255');
      expect(port, 9);
      // Fire-and-forget: "sent" is the most the app can honestly claim.
      expect(message, contains('sent'));
      await settle();
      expect(vm.wolTargets.single.lastWokenTime, greaterThan(0));
      vm.dispose();
    });

    test('deleting removes the target', () async {
      final vm = await boot(FakeProbe());
      await vm.saveWolTarget(name: 'nas', macAddress: 'aa:bb:cc:dd:ee:ff');
      await settle();
      await vm.deleteWolTarget(vm.wolTargets.single);
      await settle();
      expect(vm.wolTargets, isEmpty);
      vm.dispose();
    });
  });

  group('ping', () {
    test('streams real ICMP output and forwards the try count', () async {
      final commands = FakeDeviceCommands();
      final vm = await boot(FakeProbe(), deviceCommands: commands);
      vm.pingTarget = '10.0.0.1';
      await vm.runPing();

      expect(vm.pingLines, contains(contains('icmp_seq=1')));
      expect(vm.pingLines, contains(contains('0% packet loss')));
      expect(commands.pings, [('10.0.0.1', 4, null)]);
      vm.dispose();
    });

    test('packet loss remains command output rather than a transport error', () async {
      final vm = await boot(
        FakeProbe(),
        deviceCommands: FakeDeviceCommands(
          pingOutput: const ['4 packets transmitted, 0 received, 100% packet loss'],
        ),
      );
      vm.pingTarget = '10.0.0.99';
      await vm.runPing();

      expect(vm.pingLines.single, contains('100% packet loss'));
      expect(vm.error, isNull);
      vm.dispose();
    });

    test('an empty target is refused', () async {
      final probe = FakeProbe();
      final vm = await boot(probe);
      await vm.runPing();
      expect(vm.error, isNotNull);
      expect(probe.pinged, isEmpty);
      vm.dispose();
    });

    test('zero tries requests an until-stopped ping', () async {
      final commands = FakeDeviceCommands();
      final vm = await boot(FakeProbe(), deviceCommands: commands);
      vm
        ..pingTarget = 'example.com'
        ..pingCount = 0;
      await vm.runPing();

      expect(commands.pings, [('example.com', 0, null)]);
      vm.dispose();
    });

    test('process metacharacters are refused before launch', () async {
      final commands = FakeDeviceCommands();
      final vm = await boot(FakeProbe(), deviceCommands: commands);
      vm.pingTarget = 'example.com;id';
      await vm.runPing();

      expect(vm.error, contains('valid hostname'));
      expect(commands.pings, isEmpty);
      vm.dispose();
    });

    test('an unavailable platform says so explicitly', () async {
      final vm = await boot(FakeProbe(), deviceCommands: FakeDeviceCommands(available: false));
      vm.pingTarget = 'example.com';
      await vm.runPing();

      expect(vm.pingLines.single, contains('not available'));
      vm.dispose();
    });
  });

  group('traceroute', () {
    test('uses a native traceroute command when one exists', () async {
      final vm = await boot(
        FakeProbe(),
        deviceCommands: FakeDeviceCommands(
          tracerouteOutput: const [
            'traceroute to example.com, 30 hops max',
            ' 1  192.0.2.1  1.1 ms',
          ],
        ),
      );
      vm.tracerouteTarget = 'example.com';
      await vm.runTraceroute();

      expect(vm.tracerouteLines, contains(' 1  192.0.2.1  1.1 ms'));
      vm.dispose();
    });

    test('falls back to TTL-stepped ICMP and parses the destination', () async {
      final commands = FakeDeviceCommands(
        ttlOutput: const {
          1: ['From 192.0.2.1 icmp_seq=1 Time to live exceeded'],
          2: ['64 bytes from 198.51.100.2: icmp_seq=1 ttl=63 time=4.2 ms'],
        },
      );
      final vm = await boot(FakeProbe(), deviceCommands: commands);
      vm.tracerouteTarget = '198.51.100.2';
      await vm.runTraceroute();

      expect(vm.tracerouteLines.first, contains('TTL-stepped'));
      expect(vm.tracerouteLines, contains(contains('192.0.2.1')));
      expect(vm.tracerouteLines, contains(' 2  198.51.100.2  4.2 ms'));
      expect(vm.tracerouteLines.last, 'Trace complete.');
      expect(commands.pings.map((entry) => entry.$3), [1, 2]);
      vm.dispose();
    });

    test('rejects command metacharacters', () async {
      final commands = FakeDeviceCommands();
      final vm = await boot(FakeProbe(), deviceCommands: commands);
      vm.tracerouteTarget = 'example.com && id';
      await vm.runTraceroute();

      expect(vm.error, contains('valid hostname'));
      expect(commands.pings, isEmpty);
      vm.dispose();
    });
  });

  group('port scan', () {
    test('reports open and closed, ordered by port', () async {
      final probe = FakeProbe(open: {'10.0.0.1:22', '10.0.0.1:443'});
      final vm = await boot(probe);
      vm.portScanTarget = '10.0.0.1';
      vm.portSpec = '443,22,8080';
      await vm.runPortScan();

      expect(vm.portResults.map((r) => r.port), [22, 443, 8080]);
      expect(vm.openPorts.map((r) => r.port), [22, 443]);
      expect(vm.portResults.first.label, 'SSH');
      vm.dispose();
    });

    test('a range is expanded', () async {
      final probe = FakeProbe();
      final vm = await boot(probe);
      vm.portScanTarget = '10.0.0.1';
      vm.portSpec = '80-83';
      await vm.runPortScan();

      expect(vm.portResults.map((r) => r.port), [80, 81, 82, 83]);
      vm.dispose();
    });

    test('an unusable spec is refused with a usable message', () async {
      final probe = FakeProbe();
      final vm = await boot(probe);
      vm.portScanTarget = '10.0.0.1';
      vm.portSpec = 'nonsense';
      await vm.runPortScan();

      expect(vm.error, contains('22,80,443'));
      expect(probe.pinged, isEmpty);
      vm.dispose();
    });

    test('an empty target is refused', () async {
      final probe = FakeProbe();
      final vm = await boot(probe);
      vm.portSpec = '22';
      await vm.runPortScan();
      expect(vm.error, isNotNull);
      expect(probe.pinged, isEmpty);
      vm.dispose();
    });
  });

  group('DNS lookup', () {
    test('resolves and lists the records', () async {
      final probe = FakeProbe()..dnsResponses = {fallbackResolvers.first: aRecordResponse()};
      final vm = await boot(probe);
      vm.dnsTarget = 'example.com';
      await vm.runDnsLookup();

      expect(vm.dnsResults.single.type, 'A');
      expect(vm.dnsResults.single.value, '93.184.216.34');
      expect(vm.error, isNull);
      vm.dispose();
    });

    test('an unreachable resolver falls through to the next', () async {
      // One provider being blocked on a locked-down network is common, and reporting that as
      // "DNS is broken" would be wrong.
      final probe = FakeProbe()..dnsResponses = {fallbackResolvers[1]: aRecordResponse()};
      final vm = await boot(probe);
      vm.dnsTarget = 'example.com';
      await vm.runDnsLookup();

      expect(probe.resolversTried, fallbackResolvers.take(2));
      expect(vm.dnsResults, hasLength(1));
      vm.dispose();
    });

    test('NXDOMAIN is reported as itself and stops the fallback', () async {
      // The server answered; asking another one would turn a clear answer into a vague timeout.
      final probe = FakeProbe()
        ..dnsResponses = {
          fallbackResolvers.first: nxdomainResponse(),
          fallbackResolvers[1]: aRecordResponse(),
        };
      final vm = await boot(probe);
      vm.dnsTarget = 'nope.example';
      await vm.runDnsLookup();

      expect(vm.error, contains('No such name'));
      expect(vm.dnsResults, isEmpty);
      expect(probe.resolversTried, [fallbackResolvers.first]);
      vm.dispose();
    });

    test('every resolver failing says so plainly', () async {
      final probe = FakeProbe();
      final vm = await boot(probe);
      vm.dnsTarget = 'example.com';
      await vm.runDnsLookup();

      expect(vm.error, contains('Could not reach a DNS resolver'));
      expect(probe.resolversTried, fallbackResolvers);
      vm.dispose();
    });

    test('an empty name is refused before a packet is built', () async {
      final probe = FakeProbe();
      final vm = await boot(probe);
      await vm.runDnsLookup();
      expect(vm.error, isNotNull);
      expect(probe.resolversTried, isEmpty);
      vm.dispose();
    });

    test('an over-long label is reported rather than truncated', () async {
      final probe = FakeProbe();
      final vm = await boot(probe);
      vm.dnsTarget = '${'a' * 64}.com';
      await vm.runDnsLookup();

      expect(vm.error, contains('63 characters'));
      expect(probe.resolversTried, isEmpty);
      vm.dispose();
    });
  });

  test('a scanned host can be sent to another tool', () async {
    final vm = await boot(FakeProbe());
    vm.useHost('192.168.1.5', NetworkTab.portScan);

    expect(vm.activeTab, NetworkTab.portScan);
    expect(vm.portScanTarget, '192.168.1.5');

    vm.useHost('192.168.1.6', NetworkTab.ping);
    expect(vm.activeTab, NetworkTab.ping);
    expect(vm.pingTarget, '192.168.1.6');
    vm.dispose();
  });

  test('a scanned host action starts the tool and carries ports already found', () async {
    final probe = FakeProbe(open: {'192.168.1.5:445'});
    final vm = await boot(probe);
    vm.portSpec = '22,80';

    await vm.runForHost('192.168.1.5', NetworkTab.portScan, knownOpenPorts: const [445, 3389]);

    expect(vm.activeTab, NetworkTab.portScan);
    expect(vm.portScanTarget, '192.168.1.5');
    expect(parsePortSpec(vm.portSpec), [22, 80, 445, 3389]);
    expect(vm.openPorts.map((result) => result.port), [445]);
    vm.dispose();
  });

  group('speed test', () {
    test('publishes progress and the final throughput result', () async {
      final client = FakeSpeedTest();
      final vm = await boot(FakeProbe(), speedTest: client);

      await vm.runSpeedTest();

      expect(client.requestedUrl, NetworkViewModel.speedTestServers.first.$2);
      expect(vm.speedTestBytes, 2097152);
      expect(vm.speedTestMbps, 16.8);
      expect(vm.speedTestLatency, const Duration(milliseconds: 23));
      expect(vm.speedTestError, isNull);
      expect(vm.speedTestRunning, isFalse);
      vm.dispose();
    });

    test('refuses blank, malformed, and cleartext URLs before a request', () async {
      final client = FakeSpeedTest();
      final vm = await boot(FakeProbe(), speedTest: client);

      for (final url in ['', 'not a url', 'http://example.com/test.bin']) {
        vm.speedTestUrl = url;
        await vm.runSpeedTest();
        expect(vm.speedTestError, isNotNull);
      }
      expect(client.requestedUrl, isNull);
      vm.dispose();
    });

    test('stop cancels the active streaming request', () async {
      final client = _HoldingSpeedTest();
      final vm = await boot(FakeProbe(), speedTest: client);

      final running = vm.runSpeedTest();
      await Future<void>.delayed(Duration.zero);
      expect(vm.speedTestRunning, isTrue);
      vm.cancelSpeedTest();
      await running;

      expect(client.operation.cancelled, isTrue);
      expect(vm.speedTestRunning, isFalse);
      expect(vm.speedTestError, isNull);
      vm.dispose();
    });

    test('a cancelled run finishing late cannot clear a replacement run', () async {
      final client = _QueuedSpeedTest();
      final vm = await boot(FakeProbe(), speedTest: client);

      final first = vm.runSpeedTest();
      await Future<void>.delayed(Duration.zero);
      vm.cancelSpeedTest();
      final second = vm.runSpeedTest();
      await Future<void>.delayed(Duration.zero);

      expect(client.operations, hasLength(2));
      expect(vm.speedTestRunning, isTrue);
      await first;
      expect(
        vm.speedTestRunning,
        isTrue,
        reason: 'the cancelled run must not stop its replacement',
      );

      client.operations.last.complete(
        const SpeedTestResult(bytes: 4096, mbps: 32, latency: Duration(milliseconds: 8)),
      );
      await second;

      expect(vm.speedTestBytes, 4096);
      expect(vm.speedTestMbps, 32);
      expect(vm.speedTestRunning, isFalse);
      vm.dispose();
    });
  });

  group('whois', () {
    test('a domain is asked of IANA, then of the registry it names', () async {
      // The first answer is a delegation record; the record a user came for is at the registry.
      final whois = FakeWhois({
        'whois.iana.org': 'domain: COM\nrefer: whois.verisign-grs.com\n',
        'whois.verisign-grs.com': 'Domain Name: EXAMPLE.COM\nRegistrar: Someone\n',
      });
      final vm = await boot(FakeProbe(), whois: whois);
      vm.whoisTarget = 'example.com';
      await vm.runWhois();

      expect(whois.asked, [
        ('whois.iana.org', 'example.com'),
        ('whois.verisign-grs.com', 'example.com'),
      ]);
      // Both replies are kept: the registry says who holds the delegation, the registrar says who
      // registered it, and dropping either loses a different fact.
      expect(vm.whoisResult, contains('domain: COM'));
      expect(vm.whoisResult, contains('Registrar: Someone'));
      expect(vm.whoisServers, ['whois.iana.org', 'whois.verisign-grs.com']);
      vm.dispose();
    });

    test('an address starts at a regional registry', () async {
      final whois = FakeWhois({'whois.arin.net': 'NetRange: 8.8.8.0 - 8.8.8.255\n'});
      final vm = await boot(FakeProbe(), whois: whois);
      vm.whoisTarget = '8.8.8.8';
      await vm.runWhois();

      expect(whois.asked.single.$1, 'whois.arin.net');
      expect(vm.whoisServers, ['whois.arin.net']);
      vm.dispose();
    });

    test('a reply with no referral is the answer', () async {
      final whois = FakeWhois({'whois.iana.org': 'Domain Name: EXAMPLE.COM\n'});
      final vm = await boot(FakeProbe(), whois: whois);
      vm.whoisTarget = 'example.com';
      await vm.runWhois();

      expect(whois.asked, hasLength(1));
      expect(vm.error, isNull);
      vm.dispose();
    });

    test('a referral that is not a hostname is not followed', () async {
      // The referral is free text from a remote server and decides what this app connects to next.
      final whois = FakeWhois({
        'whois.iana.org':
            r'refer: $(curl evil.example)'
            '\n',
      });
      final vm = await boot(FakeProbe(), whois: whois);
      vm.whoisTarget = 'example.com';
      await vm.runWhois();

      expect(whois.asked, hasLength(1));
      expect(vm.whoisResult, contains('refer:'));
      vm.dispose();
    });

    test('a referral back to the server that gave it is not followed', () async {
      // Registries do point at themselves, and a second identical query is a wasted round trip.
      final whois = FakeWhois({'whois.iana.org': 'refer: whois.iana.org\n'});
      final vm = await boot(FakeProbe(), whois: whois);
      vm.whoisTarget = 'example.com';
      await vm.runWhois();

      expect(whois.asked, hasLength(1));
      vm.dispose();
    });

    test('a referred server that fails leaves the first answer standing, and says why', () async {
      // The registry reply is still a real answer; discarding it because the second hop failed
      // would turn a partial result into nothing.
      final whois = FakeWhois({
        'whois.iana.org': 'domain: COM\nrefer: whois.verisign-grs.com\n',
        'whois.verisign-grs.com': const WhoisException('Connection refused'),
      });
      final vm = await boot(FakeProbe(), whois: whois);
      vm.whoisTarget = 'example.com';
      await vm.runWhois();

      expect(vm.whoisResult, contains('domain: COM'));
      expect(vm.whoisResult, contains('did not answer'));
      expect(vm.whoisServers, ['whois.iana.org']);
      expect(vm.error, isNull, reason: 'a partial answer is not a failed lookup');
      vm.dispose();
    });

    test('a first hop that fails is reported as an error, not as an empty record', () async {
      final whois = FakeWhois({'whois.iana.org': const WhoisException('Network unreachable')});
      final vm = await boot(FakeProbe(), whois: whois);
      vm.whoisTarget = 'example.com';
      await vm.runWhois();

      expect(vm.error, contains('Network unreachable'));
      expect(vm.whoisResult, isEmpty);
      vm.dispose();
    });

    test('a blank reply says nothing came back rather than showing an empty pane', () async {
      final whois = FakeWhois({'whois.iana.org': '   \n'});
      final vm = await boot(FakeProbe(), whois: whois);
      vm.whoisTarget = 'example.com';
      await vm.runWhois();

      expect(vm.error, contains('No registration records'));
      vm.dispose();
    });

    test('an empty target asks nothing', () async {
      final whois = FakeWhois({});
      final vm = await boot(FakeProbe(), whois: whois);
      vm.whoisTarget = '   ';
      await vm.runWhois();

      expect(whois.asked, isEmpty);
      expect(vm.error, contains('Enter a domain'));
      vm.dispose();
    });

    test('a second lookup while one is running is ignored', () async {
      final whois = FakeWhois({'whois.iana.org': 'Domain Name: EXAMPLE.COM\n'});
      final vm = await boot(FakeProbe(), whois: whois);
      vm.whoisTarget = 'example.com';

      await Future.wait([vm.runWhois(), vm.runWhois()]);

      expect(whois.asked, hasLength(1));
      vm.dispose();
    });

    test('a host from the scan can be sent straight to WHOIS', () async {
      final vm = await boot(FakeProbe(), whois: FakeWhois({}));
      vm.useHost('192.168.1.9', NetworkTab.whois);

      expect(vm.whoisTarget, '192.168.1.9');
      expect(vm.activeTab, NetworkTab.whois);
      vm.dispose();
    });
  });
}
