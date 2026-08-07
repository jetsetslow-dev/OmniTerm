import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:drift/drift.dart' show Value;
import 'package:flutter/foundation.dart';

import '../../data/app_database.dart';
import '../../data/network/network_probe.dart';
import '../../data/network/whois_client.dart';
import '../../data/ssh/ssh_tunnel_manager.dart';
import '../../domain/network_tools.dart';
import '../../domain/whois.dart';
import '../../domain/server_credentials.dart';
import 'app_state.dart';

/// The Network tool's tabs, in the Kotlin's order.
enum NetworkTab { hostScan, wakeOnLan, ping, traceroute, portScan, dnsLookup, whois, tunnels }

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
  NetworkViewModel(this._app, {NetworkProbe? probe, WhoisClient? whois, this.tunnels})
    : probe = probe ?? const SocketNetworkProbe(),
      whois = whois ?? const SocketWhoisClient();

  final AppState _app;

  /// The forwarder. Nullable and injected (convention 4): without it the Tunnels tab says tunnels
  /// are unavailable rather than offering switches that do nothing.
  final SshTunnelManager? tunnels;

  /// The socket layer. Injected so the tests never touch a real network — a test that depends on
  /// the dev machine's own LAN fails elsewhere for reasons unrelated to the code.
  final NetworkProbe probe;

  /// The WHOIS transport, injected for the same reason as [probe]: a test that queries a real
  /// registry fails on a train.
  final WhoisClient whois;

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
    // Subscribed here rather than when the Tunnels tab is first opened: a tunnel can be running
    // while the user is on another tab, and the list has to know about it either way.
    startTunnels();
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

  Future<void> deleteWolTarget(WolTarget target) => _app.repository.deleteWolTargetById(target.id);

  // ── whois ───────────────────────────────────────────────────────────────────

  String whoisTarget = '';

  String _whoisResult = '';
  bool _whoisRunning = false;

  /// The registry text, exactly as the server sent it.
  String get whoisResult => _whoisResult;
  bool get whoisRunning => _whoisRunning;

  /// Which servers answered, in order, so the text on screen can be attributed. A record that came
  /// from a registrar rather than the registry is a different claim about the same domain.
  List<String> _whoisServers = const [];

  List<String> get whoisServers => List.unmodifiable(_whoisServers);

  /// Looks [whoisTarget] up, following at most one referral.
  ///
  /// One hop, and only to a host that passes [isUsableWhoisHost]: the referral is free text from a
  /// remote server and it decides what this app connects to next. A chain would also be a loop
  /// waiting to happen — registries refer to each other in both directions.
  Future<void> runWhois() async {
    if (_whoisRunning) return;
    final target = whoisTarget.trim();
    if (target.isEmpty) {
      _error = 'Enter a domain or IP address to look up.';
      _safeNotify();
      return;
    }

    _whoisRunning = true;
    _error = null;
    _whoisResult = '';
    _whoisServers = const [];
    _safeNotify();

    try {
      final first = initialWhoisServer(target);
      final response = await whois.query(first, target);
      var text = response;
      var servers = [first];

      final referral = extractReferralServer(response);
      if (referral != null && referral.toLowerCase() != first.toLowerCase()) {
        try {
          final referred = await whois.query(referral, target);
          // Both are kept. The registry reply says who owns the delegation and the registrar reply
          // says who registered it; showing only the second silently drops the authority for the
          // first, and showing only the first is the thin answer the user came here to get past.
          text = '$response\n\n─── $referral ───\n\n$referred';
          servers = [first, referral];
        } on WhoisException catch (e) {
          text = '$response\n\n[$referral did not answer: ${e.message}]';
          servers = [first];
        }
      }

      _whoisResult = text;
      _whoisServers = servers;
      if (text.trim().isEmpty) _error = 'No registration records came back for $target.';
    } on WhoisException catch (e) {
      _error = 'WHOIS lookup failed: ${e.message}';
    } catch (e) {
      _error = 'WHOIS lookup failed: $e';
    } finally {
      _whoisRunning = false;
      _safeNotify();
    }
  }

  // ── tunnels ─────────────────────────────────────────────────────────────────

  StreamSubscription<List<PortForward>>? _tunnelSub;
  List<PortForward> _portForwards = const [];

  List<PortForward> get portForwards => List.unmodifiable(_portForwards);

  bool get canTunnel => tunnels != null;

  /// Ids currently being started or stopped, so a card shows progress instead of a switch that
  /// snaps back while the connection is still dialling.
  final Set<int> _tunnelBusy = {};
  final Map<int, String> _tunnelErrors = {};

  bool isTunnelBusy(int id) => _tunnelBusy.contains(id);
  bool isTunnelActive(int id) => tunnels?.isActive(id) ?? false;
  String? tunnelError(int id) => _tunnelErrors[id];

  /// Subscribes to the saved tunnels. Called by [start]; public so a test can drive it alone.
  void startTunnels() {
    _tunnelSub ??= _app.repository.portForwardsStream.listen((list) {
      _portForwards = list;
      _safeNotify();
    });
  }

  Future<void> saveTunnel(PortForwardsCompanion row) async {
    await _app.repository.insertPortForward(row);
  }

  /// Removes a saved tunnel, stopping it first if it is up.
  ///
  /// Stopped before the row goes, not after: deleting the record while the forward is still
  /// listening would leave a port bound with nothing in the UI that can release it.
  Future<void> deleteTunnel(PortForward pf) async {
    if (isTunnelActive(pf.id)) await tunnels?.stop(pf.id);
    _tunnelErrors.remove(pf.id);
    await _app.repository.deletePortForwardById(pf.id);
  }

  /// Brings [pf] up, or takes it down if it is already running.
  Future<void> toggleTunnel(PortForward pf) async {
    final manager = tunnels;
    if (manager == null || _tunnelBusy.contains(pf.id)) return;

    _tunnelBusy.add(pf.id);
    _tunnelErrors.remove(pf.id);
    _safeNotify();
    try {
      if (manager.isActive(pf.id)) {
        await manager.stop(pf.id);
      } else {
        final server = _app.servers.where((s) => s.id == pf.serverId).firstOrNull;
        if (server == null) {
          // The host was deleted out from under the tunnel. Saying so beats a connection error
          // that blames the network.
          _tunnelErrors[pf.id] = 'The host this tunnel runs over no longer exists.';
          return;
        }
        final creds = resolveCredentials(
          server,
          keys: await _app.repository.getAllKeys(),
          profiles: await _app.repository.getAllProfiles(),
        );
        await manager.start(
          id: pf.id,
          creds: creds,
          kind: pf.kind,
          bindHost: pf.bindHost,
          bindPort: pf.bindPort,
          destHost: pf.destHost,
          destPort: pf.destPort,
        );
      }
    } on CredentialResolutionException catch (e) {
      _tunnelErrors[pf.id] = e.message;
    } catch (e) {
      _tunnelErrors[pf.id] = '$e';
    } finally {
      _tunnelBusy.remove(pf.id);
      _safeNotify();
    }
  }

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
  // ── traceroute ──────────────────────────────────────────────────────────────

  String tracerouteTarget = '';
  List<String> _tracerouteLines = const [];
  bool _tracerouteRunning = false;
  Process? _tracerouteProcess;

  List<String> get tracerouteLines => List.unmodifiable(_tracerouteLines);
  bool get tracerouteRunning => _tracerouteRunning;

  Future<void> runTraceroute() async {
    if (_tracerouteRunning) return;
    final target = tracerouteTarget.trim();
    if (target.isEmpty) {
      _error = 'Enter a valid hostname or IP address.';
      _safeNotify();
      return;
    }

    _tracerouteRunning = true;
    _error = null;
    _tracerouteLines = ['ICMP trace via TTL-stepped ping (no traceroute binary on this device)'];
    _safeNotify();

    bool reached = false;
    for (var ttl = 1; ttl <= 30; ttl++) {
      if (!_tracerouteRunning) break;
      final startedNs = DateTime.now().microsecondsSinceEpoch;
      String output = '';

      try {
        _tracerouteProcess = await Process.start(
          'ping',
          ['-c', '1', '-W', '2', '-t', ttl.toString(), target],
        );
        output = await systemEncoding.decodeStream(_tracerouteProcess!.stdout);
        await _tracerouteProcess!.exitCode;
      } catch (e) {
        _tracerouteLines = List.of(_tracerouteLines)..add('ping is not available on this device — cannot trace.');
        _safeNotify();
        break;
      } finally {
        _tracerouteProcess?.kill();
        _tracerouteProcess = null;
      }

      if (ttl == 1 && (output.toLowerCase().contains('unknown host') || output.toLowerCase().contains('name or service not known'))) {
        _tracerouteLines = List.of(_tracerouteLines)..add('Cannot resolve $target.');
        _safeNotify();
        break;
      }

      final elapsedMs = (DateTime.now().microsecondsSinceEpoch - startedNs) / 1000.0;
      final replyMatch = RegExp(r'bytes from ([0-9a-fA-F.:]*[0-9a-fA-F])[:\s].*time=([\d.]+)').firstMatch(output);
      String hopLine = '';

      if (replyMatch != null) {
        hopLine = '${ttl.toString().padLeft(2)}  ${replyMatch.group(1)}  ${replyMatch.group(2)} ms';
        reached = true;
      } else {
        final hopMatch = RegExp(r'[Ff]rom ([0-9a-fA-F.:]*[0-9a-fA-F])[:\s]').firstMatch(output);
        if (hopMatch != null) {
          hopLine = '${ttl.toString().padLeft(2)}  ${hopMatch.group(1)}  ~${elapsedMs.toStringAsFixed(0)} ms';
        } else {
          hopLine = '${ttl.toString().padLeft(2)}  *';
        }
      }

      _tracerouteLines = (List.of(_tracerouteLines)..add(hopLine)).reversed.take(200).toList().reversed.toList();
      _safeNotify();
      if (reached) break;
    }

    _tracerouteLines = List.of(_tracerouteLines)..add(reached ? 'Trace complete.' : 'Stopped after 30 hops without reaching $target.');
    _tracerouteRunning = false;
    _safeNotify();
  }

  void stopTraceroute() {
    _tracerouteProcess?.kill();
    _tracerouteRunning = false;
    _safeNotify();
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
      case NetworkTab.traceroute:
        tracerouteTarget = address;
      case NetworkTab.portScan:
        portScanTarget = address;
      case NetworkTab.dnsLookup:
        dnsTarget = address;
      case NetworkTab.hostScan:
      case NetworkTab.wakeOnLan:
      case NetworkTab.whois:
        whoisTarget = address;
      case NetworkTab.tunnels:
        return;
    }
    _activeTab = tool;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _wolSub?.cancel();
    _tunnelSub?.cancel();
    super.dispose();
  }
}

/// Convenience for tests and callers building a packet directly.
Uint8List magicPacketFor(String mac) {
  final parsed = parseMacAddress(mac);
  if (parsed == null) throw ArgumentError('Not a MAC address: $mac');
  return buildMagicPacket(parsed);
}
