import 'dart:async';
import 'dart:math';

import 'package:drift/drift.dart' show Value;
import 'package:flutter/foundation.dart';

import '../../data/app_database.dart';
import '../../data/network/network_probe.dart';
import '../../data/network/lan_hostname.dart';
import '../../data/network/device_network_command.dart';
import '../../data/network/speed_test_client.dart';
import '../../data/network/whois_client.dart';
import '../../data/ssh/ssh_tunnel_manager.dart';
import '../../domain/network_tools.dart';
import '../../domain/whois.dart';
import '../../domain/server_credentials.dart';
import 'app_state.dart';

/// The Network tool's tabs, in the Kotlin's order.
enum NetworkTab {
  hostScan,
  wakeOnLan,
  ping,
  traceroute,
  portScan,
  dnsLookup,
  whois,
  speedTest,
  tunnels,
}

/// One port probe's outcome.
class PortResult {
  const PortResult({required this.port, required this.open, this.latency});

  final int port;
  final bool open;
  final Duration? latency;

  String? get label => portLabel(port);
}

/// The Network tool's state and actions, split out of `NetworkToolView` in `ui/ToolsScreen.kt`.
class NetworkViewModel extends ChangeNotifier {
  NetworkViewModel(
    this._app, {
    NetworkProbe? probe,
    WhoisClient? whois,
    SpeedTestClient? speedTest,
    DeviceNetworkCommandRunner? deviceCommands,
    Future<Map<String, String>> Function()? arpReader,
    this.tunnels,
  }) : probe = probe ?? const SocketNetworkProbe(),
       whois = whois ?? const SocketWhoisClient(),
       speedTest = speedTest ?? DioSpeedTestClient(),
       deviceCommands = deviceCommands ?? const IoDeviceNetworkCommandRunner(),
       arpReader = arpReader ?? readSystemArpTable;

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

  final SpeedTestClient speedTest;
  final DeviceNetworkCommandRunner deviceCommands;

  /// Neighbour-cache reader used to enrich scan results with MAC/vendor data.
  ///
  /// Injected separately from [probe] because it is file I/O on Android/Linux rather than socket
  /// I/O. Widget tests use a deterministic empty table instead of accidentally reading the host's
  /// own `/proc/net/arp`.
  final Future<Map<String, String>> Function() arpReader;

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
        arpReader: arpReader,
        onProgress: (done, total) {
          _scanDone = done;
          _scanTotal = total;
          _safeNotify();
        },
      );
      // Resolve all live hosts concurrently with strict per-scheme bounds. Consumer routers rarely
      // publish PTR records, so falling back to mDNS and NetBIOS is what makes names appear for
      // Apple/Linux/IoT and Windows/Samba/NAS devices respectively.
      var nextHost = 0;
      Future<void> resolveWorker() async {
        while (nextHost < found.length) {
          final host = found[nextHost++];
          final name = await _resolveLanHostname(host.address);
          host.hostname = name.isEmpty ? null : name;
        }
      }

      // Each unnamed host opens an mDNS and NetBIOS socket. Keep that bounded on a crowded /24;
      // hundreds of simultaneous UDP sockets can exceed a phone's descriptor limit.
      final workers = found.length < 16 ? found.length : 16;
      await Future.wait([for (var i = 0; i < workers; i++) resolveWorker()]);
      _scanResults = found;
    } catch (e) {
      _error = e.toString();
    } finally {
      _scanning = false;
      _safeNotify();
    }
  }

  Future<String> _resolveLanHostname(String address) async {
    final reverse = await probe
        .reverseLookup(address)
        .timeout(const Duration(milliseconds: 1200), onTimeout: () => null);
    final normalizedReverse = LanHostnameWire.normalize(reverse, address);
    if (normalizedReverse.isNotEmpty) return normalizedReverse;

    final fallbacks = await Future.wait([
      probe.mdnsReverseLookup(address, timeout: const Duration(milliseconds: 900)),
      probe.netbiosName(address, timeout: const Duration(milliseconds: 900)),
    ]);
    final mdns = LanHostnameWire.normalize(fallbacks[0], address);
    if (mdns.isNotEmpty) return mdns;
    final netbios = LanHostnameWire.normalize(fallbacks[1], address);
    return netbios.isEmpty ? '' : LanHostnameWire.prettifyNetbios(netbios);
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
    String notes = '',
  }) async {
    if (name.trim().isEmpty) return 'Name is required.';
    if (port < 1 || port > 65535) {
      return 'UDP port must be between 1 and 65535.';
    }
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
        notes: Value(notes.trim()),
        lastWokenTime: existing == null ? const Value.absent() : Value(existing.lastWokenTime),
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
      if (text.trim().isEmpty) {
        _error = 'No registration records came back for $target.';
      }
    } on WhoisException catch (e) {
      _error = 'WHOIS lookup failed: ${e.message}';
    } catch (e) {
      _error = 'WHOIS lookup failed: $e';
    } finally {
      _whoisRunning = false;
      _safeNotify();
    }
  }

  // ── speed test ─────────────────────────────────────────────────────────────

  static const speedTestServers = <(String, String)>[
    ('Cloudflare — global anycast (50 MB)', 'https://speed.cloudflare.com/__down?bytes=52428800'),
    ('Cloudflare — global anycast (200 MB)', 'https://speed.cloudflare.com/__down?bytes=209715200'),
    ('Hetzner — Falkenstein, Germany (100 MB)', 'https://fsn1-speed.hetzner.com/100MB.bin'),
    ('Hetzner — Helsinki, Finland (100 MB)', 'https://hel1-speed.hetzner.com/100MB.bin'),
    ('Hetzner — Ashburn, US East (100 MB)', 'https://ash-speed.hetzner.com/100MB.bin'),
    ('OVH — Gravelines, France (100 MB)', 'https://proof.ovh.net/files/100Mb.dat'),
    ('Linode — Newark, US East (100 MB)', 'https://speedtest.newark.linode.com/100MB-newark.bin'),
    (
      'Linode — Fremont, US West (100 MB)',
      'https://speedtest.fremont.linode.com/100MB-fremont.bin',
    ),
    ('Linode — London, UK (100 MB)', 'https://speedtest.london.linode.com/100MB-london.bin'),
    ('Linode — Singapore (100 MB)', 'https://speedtest.singapore.linode.com/100MB-singapore.bin'),
    ('Linode — Mumbai, India (100 MB)', 'https://speedtest.mumbai1.linode.com/100MB-mumbai1.bin'),
  ];

  String speedTestUrl = speedTestServers.first.$2;
  bool _speedTestRunning = false;
  String? _speedTestError;
  double? _speedTestMbps;
  int _speedTestBytes = 0;
  Duration? _speedTestLatency;
  SpeedTestOperation? _speedTestOperation;

  bool get speedTestRunning => _speedTestRunning;
  String? get speedTestError => _speedTestError;
  double? get speedTestMbps => _speedTestMbps;
  int get speedTestBytes => _speedTestBytes;
  Duration? get speedTestLatency => _speedTestLatency;

  Future<void> runSpeedTest() async {
    if (_speedTestRunning) return;
    final url = speedTestUrl.trim();
    if (url.isEmpty) {
      _speedTestError = 'Enter a download URL.';
      _safeNotify();
      return;
    }
    final parsed = Uri.tryParse(url);
    if (parsed == null || parsed.scheme != 'https' || parsed.host.isEmpty) {
      _speedTestError = 'Enter a valid HTTPS download URL.';
      _safeNotify();
      return;
    }

    _speedTestRunning = true;
    _speedTestError = null;
    _speedTestMbps = null;
    _speedTestBytes = 0;
    _speedTestLatency = null;
    _safeNotify();

    try {
      final operation = speedTest.download(
        url,
        onProgress: (sample) {
          _speedTestBytes = sample.bytes;
          _speedTestMbps = sample.mbps;
          _safeNotify();
        },
      );
      _speedTestOperation = operation;
      final result = await operation.result;
      _speedTestBytes = result.bytes;
      _speedTestMbps = result.mbps;
      _speedTestLatency = result.latency;
    } catch (e) {
      if (_speedTestRunning) _speedTestError = 'Speed test failed: $e';
    } finally {
      _speedTestOperation = null;
      _speedTestRunning = false;
      _safeNotify();
    }
  }

  void cancelSpeedTest() {
    _speedTestRunning = false;
    _speedTestOperation?.cancel();
    _speedTestOperation = null;
    _safeNotify();
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
      await _app.repository.updateWolLastWoken(target.id, DateTime.now().millisecondsSinceEpoch);
      return 'Magic packet sent to ${target.name}. It may take a moment to boot.';
    } catch (e) {
      return 'Could not send the packet: $e';
    }
  }

  /// Best-effort online status for a WOL target without raw-socket privileges.
  Future<bool?> wolOnlineStatus(WolTarget target) async {
    final address = target.ipAddress.trim();
    if (address.isEmpty) return null;
    for (final port in const [22, 80, 443, 445]) {
      if (await probe.tcpPing(address, port, timeout: const Duration(milliseconds: 450)) != null) {
        return true;
      }
    }
    return false;
  }

  // ── ping ────────────────────────────────────────────────────────────────────

  String pingTarget = '';
  int pingCount = 4;
  List<String> _pingLines = const [];
  bool _pinging = false;
  DeviceNetworkCommand? _pingCommand;

  List<String> get pingLines => List.unmodifiable(_pingLines);
  bool get pinging => _pinging;

  Future<void> runPing() async {
    if (_pinging) return;
    final target = pingTarget.trim();
    if (!isValidNetworkCommandTarget(target)) {
      _error = 'Enter a valid hostname or IP address.';
      _safeNotify();
      return;
    }
    if (pingCount < 0 || pingCount > 9999) {
      _error = 'Tries must be between 0 and 9999.';
      _safeNotify();
      return;
    }

    _pinging = true;
    _error = null;
    _pingLines = const [];
    _safeNotify();

    try {
      final command = await deviceCommands.startPing(target, count: pingCount);
      if (command == null) {
        _pingLines = const ['ICMP ping is not available on this platform.'];
        return;
      }
      _pingCommand = command;
      if (!_pinging) {
        command.stop();
        return;
      }
      await for (final line in command.lines) {
        if (!_pinging) break;
        if (line.trim().isEmpty) continue;
        _pingLines = ([
          ..._pingLines,
          line,
        ]).reversed.take(200).toList().reversed.toList(growable: false);
        _safeNotify();
      }
      await command.exitCode;
    } catch (e) {
      _pingLines = [..._pingLines, 'ping failed: $e'];
    } finally {
      _pingCommand?.stop();
      _pingCommand = null;
      _pinging = false;
      _safeNotify();
    }
  }

  void stopPing() {
    _pinging = false;
    _pingCommand?.stop();
    _safeNotify();
  }

  // ── traceroute ──────────────────────────────────────────────────────────────

  String tracerouteTarget = '';
  List<String> _tracerouteLines = const [];
  bool _tracerouteRunning = false;
  DeviceNetworkCommand? _tracerouteCommand;

  List<String> get tracerouteLines => List.unmodifiable(_tracerouteLines);
  bool get tracerouteRunning => _tracerouteRunning;

  Future<void> runTraceroute() async {
    if (_tracerouteRunning) return;
    final target = tracerouteTarget.trim();
    if (!isValidNetworkCommandTarget(target)) {
      _error = 'Enter a valid hostname or IP address.';
      _safeNotify();
      return;
    }

    _tracerouteRunning = true;
    _error = null;
    _tracerouteLines = const [];
    _safeNotify();

    try {
      final native = await deviceCommands.startTraceroute(target);
      if (native != null) {
        _tracerouteCommand = native;
        if (!_tracerouteRunning) {
          native.stop();
          return;
        }
        await for (final line in native.lines) {
          if (!_tracerouteRunning) break;
          _appendTraceLine(line);
        }
        await native.exitCode;
        return;
      }
      await _runTtlTraceroute(target);
    } catch (e) {
      if (_tracerouteRunning) _appendTraceLine('traceroute failed: $e');
    } finally {
      _tracerouteCommand?.stop();
      _tracerouteCommand = null;
      _tracerouteRunning = false;
      _safeNotify();
    }
  }

  void stopTraceroute() {
    _tracerouteRunning = false;
    _tracerouteCommand?.stop();
    _safeNotify();
  }

  Future<void> _runTtlTraceroute(String target) async {
    _appendTraceLine('ICMP trace via TTL-stepped ping (no traceroute binary on this device)');
    var reached = false;
    var completed = true;
    for (var ttl = 1; ttl <= 30 && _tracerouteRunning; ttl++) {
      final startedUs = DateTime.now().microsecondsSinceEpoch;
      final command = await deviceCommands.startPing(target, count: 1, ttl: ttl);
      if (command == null) {
        _appendTraceLine('ping is not available on this device — cannot trace.');
        completed = false;
        break;
      }
      _tracerouteCommand = command;
      if (!_tracerouteRunning) {
        command.stop();
        completed = false;
        break;
      }
      final output = StringBuffer();
      await for (final line in command.lines) {
        output.writeln(line);
      }
      await command.exitCode;
      command.stop();
      if (!_tracerouteRunning) {
        completed = false;
        break;
      }
      final text = output.toString();
      final lower = text.toLowerCase();
      if (ttl == 1 &&
          (lower.contains('unknown host') || lower.contains('name or service not known'))) {
        _appendTraceLine('Cannot resolve $target.');
        completed = false;
        break;
      }
      final elapsedMs = (DateTime.now().microsecondsSinceEpoch - startedUs) / 1000.0;
      final reply = RegExp(
        r'bytes from ([0-9a-fA-F.:]*[0-9a-fA-F])[:\s].*time=([\d.]+)',
        caseSensitive: false,
      ).firstMatch(text);
      if (reply != null) {
        _appendTraceLine('${ttl.toString().padLeft(2)}  ${reply.group(1)}  ${reply.group(2)} ms');
        reached = true;
        break;
      }
      final hop = RegExp(
        r'from ([0-9a-fA-F.:]*[0-9a-fA-F])[:\s]',
        caseSensitive: false,
      ).firstMatch(text);
      _appendTraceLine(
        hop == null
            ? '${ttl.toString().padLeft(2)}  *'
            : '${ttl.toString().padLeft(2)}  ${hop.group(1)}  ~${elapsedMs.toStringAsFixed(0)} ms',
      );
    }
    if (!completed || !_tracerouteRunning) return;
    _appendTraceLine(
      reached ? 'Trace complete.' : 'Stopped after 30 hops without reaching $target.',
    );
  }

  void _appendTraceLine(String line) {
    if (line.trim().isEmpty) return;
    _tracerouteLines = ([
      ..._tracerouteLines,
      line,
    ]).reversed.take(200).toList().reversed.toList(growable: false);
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
      case NetworkTab.speedTest:
      case NetworkTab.tunnels:
        return;
    }
    _activeTab = tool;
    notifyListeners();
  }

  /// Sends a discovered address to an existing tool and starts that tool immediately.
  ///
  /// The native scan sheet is a one-tap action surface, not merely a field prefill. Keeping the
  /// dispatch here also makes the behaviour testable without driving the modal sheet.
  Future<void> runForHost(
    String address,
    NetworkTab tool, {
    List<int> knownOpenPorts = const [],
  }) async {
    if (tool == NetworkTab.portScan && knownOpenPorts.isNotEmpty) {
      portSpec = ({...parsePortSpec(portSpec), ...knownOpenPorts}.toList()..sort()).join(',');
    }
    useHost(address, tool);
    switch (tool) {
      case NetworkTab.ping:
        await runPing();
      case NetworkTab.traceroute:
        await runTraceroute();
      case NetworkTab.portScan:
        await runPortScan();
      case NetworkTab.dnsLookup:
        await runDnsLookup();
      case NetworkTab.whois:
        await runWhois();
      case NetworkTab.hostScan ||
          NetworkTab.wakeOnLan ||
          NetworkTab.speedTest ||
          NetworkTab.tunnels:
        return;
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _pingCommand?.stop();
    _tracerouteCommand?.stop();
    _wolSub?.cancel();
    _tunnelSub?.cancel();
    _speedTestOperation?.cancel();
    super.dispose();
  }
}

/// Convenience for tests and callers building a packet directly.
Uint8List magicPacketFor(String mac) {
  final parsed = parseMacAddress(mac);
  if (parsed == null) throw ArgumentError('Not a MAC address: $mac');
  return buildMagicPacket(parsed);
}
