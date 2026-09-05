import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../../domain/network_tools.dart';
import 'lan_hostname.dart';

/// The socket work behind the Network tools.
///
/// An interface rather than free functions so the view model can be tested without touching a real
/// network — a test that depends on the machine's own LAN is a test that fails on a laptop in a
/// café and passes on the dev box, which is exactly the host dependence the test fleet prevents.
abstract interface class NetworkProbe {
  /// Round-trip time to [host]:[port], or null when it did not answer in [timeout].
  ///
  /// A TCP connect rather than ICMP: an echo request needs a raw socket, which needs root on
  /// Android and is unavailable to a sandboxed iOS app. Connecting to a port the host is listening
  /// on measures the same round trip and works unprivileged — the cost is that a host which is up
  /// but has nothing listening reads as down, which the UI says.
  Future<Duration?> tcpPing(String host, int port, {Duration timeout});

  /// Sends a Wake-on-LAN magic packet to [broadcast]:[port].
  Future<void> sendMagicPacket(Uint8List packet, String broadcast, int port);

  /// Sends [query] to a DNS resolver and returns the raw response.
  Future<Uint8List> resolve(Uint8List query, {required String resolver, Duration timeout});

  /// Reverse-resolves [address] to a hostname, or null.
  Future<String?> reverseLookup(String address);

  /// Reverse mDNS PTR lookup for LANs whose DHCP server publishes no ordinary PTR records.
  Future<String?> mdnsReverseLookup(String address, {Duration timeout});

  /// NetBIOS node-status name for Windows, Samba and NAS devices.
  Future<String?> netbiosName(String address, {Duration timeout});

  /// The device's own IPv4 address on a local interface, used to guess the subnet to sweep.
  Future<String?> localAddress();
}

/// The real implementation, over `dart:io`.
class SocketNetworkProbe implements NetworkProbe {
  const SocketNetworkProbe();

  @override
  Future<Duration?> tcpPing(
    String host,
    int port, {
    Duration timeout = const Duration(seconds: 2),
  }) async {
    final stopwatch = Stopwatch()..start();
    Socket? socket;
    try {
      socket = await Socket.connect(host, port, timeout: timeout);
      return stopwatch.elapsed;
    } on SocketException {
      return null;
    } on TimeoutException {
      return null;
    } finally {
      // Destroy rather than close: a graceful close waits for the peer, and a probe has no reason
      // to keep a socket open for a handshake it does not care about.
      socket?.destroy();
    }
  }

  @override
  Future<void> sendMagicPacket(Uint8List packet, String broadcast, int port) async {
    final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    try {
      // Without this the OS refuses a datagram addressed to a broadcast address, and the packet
      // never leaves the device.
      socket.broadcastEnabled = true;
      socket.send(packet, InternetAddress(broadcast), port);
      // The datagram is queued, not sent, when `send` returns; closing immediately can drop it.
      await Future<void>.delayed(const Duration(milliseconds: 50));
    } finally {
      socket.close();
    }
  }

  @override
  Future<Uint8List> resolve(
    Uint8List query, {
    required String resolver,
    Duration timeout = const Duration(seconds: 3),
  }) async {
    final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    final completer = Completer<Uint8List>();
    StreamSubscription<RawSocketEvent>? subscription;

    try {
      subscription = socket.listen((event) {
        if (event != RawSocketEvent.read) return;
        final datagram = socket.receive();
        if (datagram == null) return;
        if (!completer.isCompleted) {
          completer.complete(Uint8List.fromList(datagram.data));
        }
      });

      socket.send(query, InternetAddress(resolver), 53);
      return await completer.future.timeout(timeout);
    } finally {
      await subscription?.cancel();
      socket.close();
    }
  }

  @override
  Future<String?> reverseLookup(String address) async {
    try {
      final result = await InternetAddress(address).reverse();
      // A resolver with no PTR record echoes the address back; reporting that as a hostname would
      // fill the scan list with rows that look resolved but are not.
      return result.host == address ? null : result.host;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<String?> mdnsReverseLookup(
    String address, {
    Duration timeout = const Duration(milliseconds: 900),
  }) async {
    final query = LanHostnameWire.buildReversePtrQuery(address);
    if (query == null) return null;
    final response = await _udpQuery(
      query,
      destination: '224.0.0.251',
      port: 5353,
      timeout: timeout,
    );
    return response == null ? null : LanHostnameWire.parsePtrAnswer(response);
  }

  @override
  Future<String?> netbiosName(
    String address, {
    Duration timeout = const Duration(milliseconds: 900),
  }) async {
    final response = await _udpQuery(
      LanHostnameWire.buildNetbiosNodeStatusQuery(),
      destination: address,
      port: 137,
      timeout: timeout,
    );
    return response == null ? null : LanHostnameWire.parseNetbiosNodeStatus(response);
  }

  Future<Uint8List?> _udpQuery(
    Uint8List query, {
    required String destination,
    required int port,
    required Duration timeout,
  }) async {
    RawDatagramSocket? socket;
    StreamSubscription<RawSocketEvent>? subscription;
    final answer = Completer<Uint8List?>();
    try {
      socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      subscription = socket.listen((event) {
        if (event != RawSocketEvent.read) return;
        final packet = socket?.receive();
        if (packet != null && !answer.isCompleted) {
          answer.complete(Uint8List.fromList(packet.data));
        }
      });
      socket.send(query, InternetAddress(destination), port);
      return await answer.future.timeout(timeout, onTimeout: () => null);
    } catch (_) {
      return null;
    } finally {
      await subscription?.cancel();
      socket?.close();
    }
  }

  @override
  Future<String?> localAddress() async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
      for (final interface in interfaces) {
        for (final address in interface.addresses) {
          if (!address.isLoopback) return address.address;
        }
      }
    } catch (_) {
      // Enumerating interfaces needs a permission on some platforms; the user can type a subnet.
    }
    return null;
  }
}

/// A host found by a subnet sweep.
class ScannedHost {
  ScannedHost({
    required this.address,
    this.hostname,
    this.macAddress = '',
    this.vendor = '',
    this.latency,
    this.openPorts = const [],
  });

  final String address;
  String? hostname;
  String macAddress;
  String vendor;
  Duration? latency;
  List<int> openPorts;
}

const _ouiVendors = <String, String>{
  'B8:27:EB': 'Raspberry Pi',
  'DC:A6:32': 'Raspberry Pi',
  'E4:5F:01': 'Raspberry Pi',
  '28:CD:C1': 'Raspberry Pi',
  '00:1A:11': 'Google',
  'F4:F5:E8': 'Google',
  'DA:A1:19': 'Google',
  'EC:FA:BC': 'Espressif',
  '24:0A:C4': 'Espressif',
  'A0:20:A6': 'Espressif',
  'FC:FB:FB': 'Apple',
  'AC:DE:48': 'Apple',
  'F0:18:98': 'Apple',
  'A4:83:E7': 'Apple',
  '00:1B:63': 'Apple',
  '3C:15:C2': 'Apple',
  '44:D9:E7': 'Ubiquiti',
  'FC:EC:DA': 'Ubiquiti',
  '78:8A:20': 'Ubiquiti',
  '00:50:56': 'VMware',
  '08:00:27': 'VirtualBox',
  '52:54:00': 'QEMU/KVM',
  '00:15:5D': 'Microsoft Hyper-V',
};

String vendorForMac(String mac) =>
    mac.length < 8 ? '' : _ouiVendors[mac.substring(0, 8).toUpperCase()] ?? '';

/// Best-effort Android/Linux neighbour-cache reader.
///
/// Recent Android versions may deny this file. An empty map is expected there; the active TCP
/// sweep still works, while platforms that expose it gain MAC addresses and ping-only neighbours.
Future<Map<String, String>> readSystemArpTable() async {
  final result = <String, String>{};
  try {
    final file = File('/proc/net/arp');
    if (!await file.exists()) return result;
    final lines = await file.readAsLines();
    for (final line in lines.skip(1)) {
      final parts = line.trim().split(RegExp(r'\s+'));
      if (parts.length < 4) continue;
      final mac = parts[3].toUpperCase();
      if (RegExp(r'^[0-9A-F]{2}(?::[0-9A-F]{2}){5}$').hasMatch(mac) && mac != '00:00:00:00:00:00') {
        result[parts[0]] = mac;
      }
    }
  } catch (_) {
    // Sandboxed platforms commonly reject the read; MAC enrichment is optional.
  }
  return result;
}

/// Sweeps a `/24` for hosts that answer on any of [ports].
///
/// Concurrency is capped: 254 addresses times several ports each, all at once, exhausts the file
/// descriptors of a mobile process and makes the sweep slower than doing it in batches.
Future<List<ScannedHost>> sweepSubnet(
  NetworkProbe probe,
  String prefix, {
  List<int> ports = const [22, 80, 443, 445, 3389, 5900, 8080],
  int concurrency = 32,
  Duration timeout = const Duration(milliseconds: 400),
  Future<Map<String, String>> Function()? arpReader,
  void Function(int done, int total)? onProgress,
}) async {
  final addresses = hostsInSubnet(prefix);
  final found = <ScannedHost>[];
  var done = 0;

  final queue = List<String>.from(addresses);
  Future<void> worker() async {
    while (queue.isNotEmpty) {
      final address = queue.removeAt(0);
      final open = <int>[];
      Duration? best;
      for (final port in ports) {
        final rtt = await probe.tcpPing(address, port, timeout: timeout);
        if (rtt == null) continue;
        open.add(port);
        if (best == null || rtt < best) best = rtt;
      }
      if (open.isNotEmpty) {
        found.add(ScannedHost(address: address, latency: best, openPorts: open));
      }
      onProgress?.call(++done, addresses.length);
    }
  }

  await Future.wait([for (var i = 0; i < concurrency; i++) worker()]);

  final arp = await arpReader?.call() ?? const <String, String>{};
  final byAddress = {for (final host in found) host.address: host};
  for (final entry in arp.entries) {
    if (subnetPrefixOf(entry.key) != prefix) continue;
    final host = byAddress.putIfAbsent(entry.key, () => ScannedHost(address: entry.key));
    host.macAddress = entry.value;
    host.vendor = vendorForMac(entry.value);
  }
  found
    ..clear()
    ..addAll(byAddress.values);

  // Sorted numerically by last octet, not lexically: otherwise .10 sorts before .9 and the list
  // reads as though addresses are missing.
  found.sort((a, b) {
    final aLast = int.tryParse(a.address.split('.').last) ?? 0;
    final bLast = int.tryParse(b.address.split('.').last) ?? 0;
    return aLast.compareTo(bLast);
  });
  return found;
}
