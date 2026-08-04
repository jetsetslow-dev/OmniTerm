import 'dart:async';
import 'dart:math';

import 'package:drift/drift.dart' show Value;
import 'package:flutter/foundation.dart';

import '../../data/app_database.dart';
import '../../data/network/network_probe.dart';
import '../../domain/network_tools.dart';
import 'app_state.dart';

/// The Network tool's tabs, in the Kotlin's order.
enum NetworkTab { hostScan, wakeOnLan, ping, portScan, dnsLookup }

/// One port probe's outcome.
class PortResult {
  const PortResult({required this.port, required this.open, this.latency});

  final int port;
  final bool open;
  final Duration? latency;

  String? get label => portLabel(port);
}

/// One ping attempt.
class PingResult {
  const PingResult({required this.sequence, required this.latency});

  final int sequence;

  /// Null when the attempt timed out.
  final Duration? latency;
}

/// The Network tool's state and actions, split out of `NetworkToolView` in `ui/ToolsScreen.kt`.
class NetworkViewModel extends ChangeNotifier {
  NetworkViewModel(this._app, {NetworkProbe? probe}) : probe = probe ?? const SocketNetworkProbe();

  final AppState _app;

  /// The socket layer. Injected so the tests never touch a real network — a test that depends on
  /// the dev machine's own LAN fails elsewhere for reasons unrelated to the code.
  final NetworkProbe probe;

  bool _disposed = false;

  void _safeNotify() {
    if (!_disposed) notifyListeners();
  }

  NetworkTab _activeTab = NetworkTab.hostScan;

  NetworkTab get activeTab => _activeTab;

  set activeTab(NetworkTab value) {
    if (_activeTab == value) return;
    _activeTab = value;
    notifyListeners();
  }

  String? _error;

  String? get error => _error;

  void dismissError() {
    _error = null;
    notifyListeners();
  }

  // ── host scan ───────────────────────────────────────────────────────────────

  String _subnetPrefix = '';
  List<ScannedHost> _scanResults = const [];
  bool _scanning = false;
  int _scanDone = 0;
  int _scanTotal = 0;

  /// The `/24` to sweep, e.g. `192.168.1`.
  String get subnetPrefix => _subnetPrefix;

  set subnetPrefix(String value) {
    if (_subnetPrefix == value) return;
    _subnetPrefix = value;
    notifyListeners();
  }

  List<ScannedHost> get scanResults => List.unmodifiable(_scanResults);
  bool get scanning => _scanning;

  /// 0..1, or null before a sweep starts.
  double? get scanProgress => _scanTotal == 0 ? null : _scanDone / _scanTotal;

  /// Fills [subnetPrefix] from the device's own address, when it is empty.
  ///
  /// A guess the user can correct beats an empty field: on a home network the answer is almost
  /// always the device's own `/24`, and typing one out on a phone is tedious.
  Future<void> guessSubnet() async {
    if (_subnetPrefix.isNotEmpty) return;
    final address = await probe.localAddress();
    final prefix = address == null ? null : subnetPrefixOf(address);
    if (prefix != null) {
      _subnetPrefix = prefix;
      _safeNotify();
    }
  }

  Future<void> scanSubnet() async {
    if (_scanning) return;
    final prefix = _subnetPrefix.trim();
    if (subnetPrefixOf('$prefix.1') == null) {
      _error = 'Enter a subnet like 192.168.1';
      _safeNotify();
      return;
    }

    _scanning = true;
    _error = null;
    _scanResults = const [];
    _scanDone = 0;
    _scanTotal = 254;
    _safeNotify();

    try {
      final found = await sweepSubnet(
        probe,
        prefix,
        onProgress: (done, total) {
          _scanDone = done;
          _scanTotal = total;
          _safeNotify();
        },
      );
      // Names are resolved after the sweep, not during: a slow or absent PTR server would otherwise
      // hold up the whole scan behind lookups nobody asked for.
      for (final host in found) {
        host.hostname = await probe.reverseLookup(host.address);
      }
      _scanResults = found;
    } catch (e) {
      _error = e.toString();
    } finally {
      _scanning = false;
      _safeNotify();
    }
  }

  // ── wake on LAN ─────────────────────────────────────────────────────────────

  List<WolTarget> _wolTargets = const [];
  StreamSubscription<List<WolTarget>>? _wolSub;

  List<WolTarget> get wolTargets => List.unmodifiable(_wolTargets);

  Future<void> start() async {
    _wolSub ??= _app.repository.wolTargetsStream.listen((list) {
      _wolTargets = list;
      _safeNotify();
    });
    await guessSubnet();
  }

  /// Saves a Wake-on-LAN target. Returns null on success.
  Future<String?> saveWolTarget({
    WolTarget? existing,
    required String name,
    required String macAddress,
    String broadcastIp = '',
    String ipAddress = '',
    int port = 9,
  }) async {
    if (name.trim().isEmpty) return 'Name is required.';
    final mac = parseMacAddress(macAddress);
    // Refusing here rather than at send time: a saved target with an unusable MAC would look fine
    // in the list and silently do nothing every time it was tapped.
    if (mac == null) return 'That is not a MAC address.';

    // Prefer what the user typed; otherwise derive the directed broadcast from the host's own
    // address, which is what actually reaches a sleeping machine on a routed network. The global
    // 255.255.255.255 is the last resort — many routers drop it.
    final explicitBroadcast = broadcastIp.trim();
    final hostPrefix = subnetPrefixOf(ipAddress.trim());
    final broadcast = explicitBroadcast.isNotEmpty
        ? explicitBroadcast
        : hostPrefix != null
            ? broadcastFor(hostPrefix)
            : '255.255.255.255';

    await _app.repository.insertWolTarget(
      WolTargetsCompanion.insert(
        id: existing == null ? const Value.absent() : Value(existing.id),
        name: name.trim(),
        macAddress: formatMacAddress(mac),
        broadcastIp: Value(broadcast),
        ipAddress: Value(ipAddress.trim()),
        port: Value(port),
      ),
    );
    return null;
  }

  Future<void> deleteWolTarget(WolTarget target) =>
      _app.repository.deleteWolTargetById(target.id);

  /// Sends the magic packet for [target].
  ///
  /// Returns a message describing what happened, because there is no acknowledgement to wait for:
  /// Wake-on-LAN is fire-and-forget, and saying "sent" is the most honest thing the app can claim.
  Future<String> wake(WolTarget target) async {
    final mac = parseMacAddress(target.macAddress);
    if (mac == null) return 'That target has an invalid MAC address.';
    try {
      await probe.sendMagicPacket(
        buildMagicPacket(mac),
        target.broadcastIp.isEmpty ? '255.255.255.255' : target.broadcastIp,
        target.port,
      );
      return 'Magic packet sent to ${target.name}. It may take a moment to boot.';
    } catch (e) {
      return 'Could not send the packet: $e';
    }
  }

  // ── ping ────────────────────────────────────────────────────────────────────

  String pingTarget = '';
  int pingPort = 22;
  List<PingResult> _pingResults = const [];
  bool _pinging = false;

  List<PingResult> get pingResults => List.unmodifiable(_pingResults);
  bool get pinging => _pinging;

  /// How many attempts one run makes.
  static const pingAttempts = 4;

  /// Successful attempts as a percentage, or null before a run.
  double? get pingSuccessRate {
    if (_pingResults.isEmpty) return null;
    final ok = _pingResults.where((r) => r.latency != null).length;
    return ok * 100 / _pingResults.length;
  }

  /// Mean round trip of the successful attempts, or null when none answered.
  Duration? get pingAverage {
    final ok = _pingResults.where((r) => r.latency != null).toList();
    if (ok.isEmpty) return null;
    final total = ok.fold<int>(0, (sum, r) => sum + r.latency!.inMicroseconds);
    return Duration(microseconds: total ~/ ok.length);
  }

  Future<void> runPing() async {
    if (_pinging) return;
    final target = pingTarget.trim();
    if (target.isEmpty) {
      _error = 'Enter a host to ping.';
      _safeNotify();
      return;
    }

    _pinging = true;
    _error = null;
    _pingResults = const [];
    _safeNotify();

    try {
      final results = <PingResult>[];
      for (var attempt = 1; attempt <= pingAttempts; attempt++) {
        final latency = await probe.tcpPing(target, pingPort);
        results.add(PingResult(sequence: attempt, latency: latency));
        // Published as they arrive: watching the first reply land is the point of a ping, and a
        // four-second wait for all of them at once is not.
        _pingResults = List.of(results);
        _safeNotify();
      }
    } catch (e) {
      _error = e.toString();
    } finally {
      _pinging = false;
      _safeNotify();
    }
  }

  // ── port scan ───────────────────────────────────────────────────────────────

  String portScanTarget = '';
  String portSpec = commonPorts.join(',');
  List<PortResult> _portResults = const [];
  bool _portScanning = false;

  List<PortResult> get portResults => List.unmodifiable(_portResults);
  bool get portScanning => _portScanning;

  /// Only the open ports — what a scan is actually asked for.
  List<PortResult> get openPorts => _portResults.where((r) => r.open).toList();

  Future<void> runPortScan() async {
    if (_portScanning) return;
    final target = portScanTarget.trim();
    if (target.isEmpty) {
      _error = 'Enter a host to scan.';
      _safeNotify();
      return;
    }
    final ports = parsePortSpec(portSpec);
    if (ports.isEmpty) {
      _error = 'Enter ports like 22,80,443 or 8000-8100 (up to $maxPortsPerScan at a time).';
      _safeNotify();
      return;
    }

    _portScanning = true;
    _error = null;
    _portResults = const [];
    _safeNotify();

    try {
      final results = <PortResult>[];
      final queue = List<int>.from(ports);
      Future<void> worker() async {
        while (queue.isNotEmpty) {
          final port = queue.removeAt(0);
          final latency = await probe.tcpPing(target, port, timeout: const Duration(seconds: 1));
          results.add(PortResult(port: port, open: latency != null, latency: latency));
          _portResults = List.of(results)..sort((a, b) => a.port.compareTo(b.port));
          _safeNotify();
        }
      }

      // Bounded fan-out: opening a socket per port at once exhausts a mobile process's descriptors
      // and makes the scan slower, not faster.
      await Future.wait([for (var i = 0; i < min(32, ports.length); i++) worker()]);
    } catch (e) {
      _error = e.toString();
    } finally {
      _portScanning = false;
      _safeNotify();
    }
  }

  // ── DNS ─────────────────────────────────────────────────────────────────────

  String dnsTarget = '';
  String dnsType = 'A';
  List<DnsRecord> _dnsResults = const [];
  bool _resolving = false;

  List<DnsRecord> get dnsResults => List.unmodifiable(_dnsResults);
  bool get resolving => _resolving;

  Future<void> runDnsLookup() async {
    if (_resolving) return;
    final target = dnsTarget.trim();
    if (target.isEmpty) {
      _error = 'Enter a name to look up.';
      _safeNotify();
      return;
    }

    _resolving = true;
    _error = null;
    _dnsResults = const [];
    _safeNotify();

    // A transaction id per query, so a late reply to a previous question cannot be read as this
    // one's answer.
    final transactionId = Random().nextInt(0xFFFF);

    try {
      final query = buildDnsQuery(target, dnsTypeCode(dnsType), transactionId: transactionId);
      Object? lastFailure;

      for (final resolver in fallbackResolvers) {
        try {
          final response = await probe.resolve(query, resolver: resolver);
          _dnsResults = parseDnsResponse(response, expectTransactionId: transactionId);
          if (_dnsResults.isEmpty) {
            _error = 'No ${dnsType.toUpperCase()} records for $target.';
          }
          return;
        } on DnsException catch (e) {
          // The server answered and said no — trying another resolver would not change that, and
          // would turn a clear "no such name" into a vague timeout.
          _error = e.message;
          return;
        } catch (e) {
          lastFailure = e;
        }
      }
      _error = 'Could not reach a DNS resolver: $lastFailure';
    } on DnsException catch (e) {
      _error = e.message;
    } finally {
      _resolving = false;
      _safeNotify();
    }
  }

  /// Fills a tool's target field from a scanned host and switches to that tool.
  void useHost(String address, NetworkTab tool) {
    switch (tool) {
      case NetworkTab.ping:
        pingTarget = address;
      case NetworkTab.portScan:
        portScanTarget = address;
      case NetworkTab.dnsLookup:
        dnsTarget = address;
      case NetworkTab.hostScan:
      case NetworkTab.wakeOnLan:
        return;
    }
    _activeTab = tool;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _wolSub?.cancel();
    super.dispose();
  }
}

/// Convenience for tests and callers building a packet directly.
Uint8List magicPacketFor(String mac) {
  final parsed = parseMacAddress(mac);
  if (parsed == null) throw ArgumentError('Not a MAC address: $mac');
  return buildMagicPacket(parsed);
}
