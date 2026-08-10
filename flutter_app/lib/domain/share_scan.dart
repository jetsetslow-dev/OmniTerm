/// Finding file shares on the local network.
///
/// Ported from `scanNetworkShares` and `networkShareScanProtocols` (`ui/AppViewModel.kt:7372`,
/// `:1177`). Flutter's Shares tab could only add a share by typing its address, so a NAS had to be
/// known before it could be saved — the discovery half of the feature was absent entirely.
///
/// The sweep itself reuses `sweepSubnet` rather than repeating Kotlin's bespoke connect loop: it
/// already caps concurrency, applies a timeout and reports progress, and a second implementation of
/// that would be a second place for those limits to drift.
library;

import '../data/network/network_probe.dart';

/// The protocols worth probing for, and the ports that mean each one is there.
///
/// WebDAV has two because it is served over both plain HTTP and TLS, and a NAS commonly answers on
/// only one of them.
const Map<String, List<int>> shareScanPorts = {
  'SMB': [445],
  'FTP': [21],
  'SFTP': [22],
  'NFS': [2049],
  'WEBDAV': [80, 443],
};

/// Every protocol the scanner understands, in the order the UI offers them.
List<String> get allScanProtocols => shareScanPorts.keys.toList();

/// The settings row the protocol selection lives in — Kotlin's key, unchanged, so an upgraded
/// install keeps the choice the user already made.
const String shareScanProtocolsKey = 'share_scan_protocols';

/// The ports to sweep for [enabled], deduplicated and ordered.
///
/// Ordered rather than set-ordered so the sweep is reproducible: a test that pins the ports probed
/// should not depend on hash iteration order.
List<int> portsForProtocols(Iterable<String> enabled) {
  final chosen = enabled.toSet();
  final ports = <int>[];
  for (final entry in shareScanPorts.entries) {
    if (!chosen.contains(entry.key)) continue;
    for (final port in entry.value) {
      if (!ports.contains(port)) ports.add(port);
    }
  }
  return ports;
}

String encodeScanProtocols(Iterable<String> protocols) => protocols.join(',');

/// The stored protocol selection, falling back to everything.
///
/// **Never returns empty.** A stored value naming nothing known would otherwise leave a scanner that
/// probes no ports and reports "no shares found" — indistinguishable from a quiet network, and
/// wrong. All protocols is the same default Kotlin ships.
List<String> decodeScanProtocols(String? raw) {
  if (raw == null) return allScanProtocols;
  final stored = raw
      .split(',')
      .map((s) => s.trim().toUpperCase())
      .where(shareScanPorts.containsKey)
      .toList();
  return stored.isEmpty ? allScanProtocols : stored;
}

/// Turns [prefix] input into the first three octets `hostsInSubnet` wants, or null when it is not a
/// subnet at all.
///
/// Accepts what a person actually types: `192.168.1.0/24`, `192.168.1.0`, or `192.168.1`. The mask
/// is read but not honoured beyond /24 — the sweep is a single 254-address range, and pretending to
/// support /16 would promise a scan of 65k hosts that no phone should attempt.
String? scanPrefixOf(String input) {
  final trimmed = input.trim();
  if (trimmed.isEmpty) return null;
  final withoutMask = trimmed.split('/').first;
  final octets = withoutMask.split('.').where((o) => o.trim().isNotEmpty).toList();
  if (octets.length < 3) return null;
  for (final octet in octets.take(3)) {
    final value = int.tryParse(octet);
    if (value == null || value < 0 || value > 255) return null;
  }
  return octets.take(3).join('.');
}

/// One share service found on the network.
class ShareScanHit {
  const ShareScanHit({required this.address, required this.protocol, required this.port});

  final String address;
  final String protocol;
  final int port;

  /// What the row reads as.
  String get label => '$protocol on $address:$port';

  /// Identity is the endpoint, so the same service found twice is one row.
  @override
  bool operator ==(Object other) =>
      other is ShareScanHit &&
      other.address == address &&
      other.protocol == protocol &&
      other.port == port;

  @override
  int get hashCode => Object.hash(address, protocol, port);
}

/// The share services implied by a subnet sweep.
///
/// A host answering on 445 is offering SMB; that is the whole inference, and it is the same one
/// Kotlin makes. It is a **probe, not a handshake** — an open port is evidence a service is
/// listening, not proof it will accept these credentials, which is what the existing per-share test
/// action is for.
List<ShareScanHit> hitsFromScan(Iterable<ScannedHost> hosts, Iterable<String> enabled) {
  final chosen = enabled.toSet();
  final hits = <ShareScanHit>[];
  for (final host in hosts) {
    for (final entry in shareScanPorts.entries) {
      if (!chosen.contains(entry.key)) continue;
      for (final port in entry.value) {
        if (!host.openPorts.contains(port)) continue;
        final hit = ShareScanHit(address: host.address, protocol: entry.key, port: port);
        if (!hits.contains(hit)) hits.add(hit);
      }
    }
  }
  return hits;
}
