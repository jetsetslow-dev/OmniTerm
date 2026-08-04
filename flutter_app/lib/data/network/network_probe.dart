import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../../domain/network_tools.dart';

/// The socket work behind the Network tools.
///
/// An interface rather than free functions so the view model can be tested without touching a real
/// network — a test that depends on the machine's own LAN is a test that fails on a laptop in a
/// café and passes on the dev box, which is exactly the host-dependence MIGRATION.md warns about.
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
  ScannedHost({required this.address, this.hostname, this.latency, this.openPorts = const []});

  final String address;
  String? hostname;
  Duration? latency;
  List<int> openPorts;
}

/// Sweeps a `/24` for hosts that answer on any of [ports].
///
/// Concurrency is capped: 254 addresses times several ports each, all at once, exhausts the file
/// descriptors of a mobile process and makes the sweep slower than doing it in batches.
Future<List<ScannedHost>> sweepSubnet(
  NetworkProbe probe,
  String prefix, {
  List<int> ports = const [22, 80, 443, 445],
  int concurrency = 32,
  Duration timeout = const Duration(milliseconds: 400),
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

  // Sorted numerically by last octet, not lexically: otherwise .10 sorts before .9 and the list
  // reads as though addresses are missing.
  found.sort((a, b) {
    final aLast = int.tryParse(a.address.split('.').last) ?? 0;
    final bLast = int.tryParse(b.address.split('.').last) ?? 0;
    return aLast.compareTo(bLast);
  });
  return found;
}
