/// Pure protocol logic for the Network tools — magic packets, DNS wire format, port lists and
/// subnet enumeration.
///
/// Written against the protocols themselves rather than transcribed from the Kotlin (§16.4). Kept
/// free of `dart:io` so every byte-level decision is testable without a socket: DNS in particular
/// is a format where an off-by-one in a length prefix produces a query a server silently ignores,
/// which is indistinguishable from "no records" at the UI.
library;

import 'dart:convert';
import 'dart:typed_data';

// ── Wake-on-LAN ───────────────────────────────────────────────────────────────

/// Parses a MAC address in any of the usual separators, or null when it is not one.
///
/// Accepts `aa:bb:cc:dd:ee:ff`, `aa-bb-...`, `aabb.ccdd.eeff` and bare hex, because a MAC gets
/// copied out of a router UI, `ip link`, or a sticker — and each writes it differently.
Uint8List? parseMacAddress(String mac) {
  final hex = mac.replaceAll(RegExp(r'[:\-.\s]'), '');
  if (hex.length != 12) return null;
  if (!RegExp(r'^[0-9a-fA-F]{12}$').hasMatch(hex)) return null;
  return Uint8List.fromList([
    for (var i = 0; i < 12; i += 2) int.parse(hex.substring(i, i + 2), radix: 16),
  ]);
}

/// Formats six bytes as `aa:bb:cc:dd:ee:ff`.
String formatMacAddress(Uint8List mac) =>
    mac.map((b) => b.toRadixString(16).padLeft(2, '0')).join(':');

/// Builds the Wake-on-LAN magic packet for [mac].
///
/// The format is fixed by the standard: six `0xFF` bytes, then the target MAC repeated sixteen
/// times — 102 bytes total. A network card in low-power mode scans for exactly this pattern, so
/// every byte matters and there is nothing to tune.
Uint8List buildMagicPacket(Uint8List mac) {
  if (mac.length != 6) {
    throw ArgumentError('A MAC address is six bytes, got ${mac.length}');
  }
  final packet = Uint8List(6 + 16 * 6)..fillRange(0, 6, 0xFF);
  for (var repeat = 0; repeat < 16; repeat++) {
    packet.setRange(6 + repeat * 6, 6 + repeat * 6 + 6, mac);
  }
  return packet;
}

// ── port lists ────────────────────────────────────────────────────────────────

/// The ports offered by default, chosen because finding one open tells you what a machine *is*.
const commonPorts = [
  21,
  22,
  23,
  25,
  53,
  80,
  110,
  143,
  443,
  445,
  587,
  993,
  995,
  1433,
  3306,
  3389,
  5432,
  5900,
  6379,
  8006,
  8080,
  8443,
  9090,
  27017,
];

/// A short label for a well-known port, or null.
///
/// Shown next to the number because "8006 open" means nothing to most people and "8006 (Proxmox)"
/// immediately does.
String? portLabel(int port) => switch (port) {
  21 => 'FTP',
  22 => 'SSH',
  23 => 'Telnet',
  25 => 'SMTP',
  53 => 'DNS',
  80 => 'HTTP',
  110 => 'POP3',
  143 => 'IMAP',
  443 => 'HTTPS',
  445 => 'SMB',
  587 => 'SMTP submission',
  993 => 'IMAPS',
  995 => 'POP3S',
  1433 => 'MSSQL',
  3306 => 'MySQL',
  3389 => 'RDP',
  5432 => 'PostgreSQL',
  5900 => 'VNC',
  6379 => 'Redis',
  8006 => 'Proxmox',
  8080 => 'HTTP alt',
  8443 => 'HTTPS alt',
  9090 => 'Cockpit',
  27017 => 'MongoDB',
  _ => null,
};

/// Parses a port specification: a comma-separated list of numbers and `from-to` ranges.
///
/// Out-of-range and unparseable entries are dropped rather than failing the whole list — a stray
/// comma should not stop the other twenty ports being scanned. The result is sorted and
/// de-duplicated so the same port is never probed twice.
List<int> parsePortSpec(String spec) {
  final ports = <int>{};
  for (final part in spec.split(',')) {
    final trimmed = part.trim();
    if (trimmed.isEmpty) continue;

    final range = RegExp(r'^(\d+)\s*-\s*(\d+)$').firstMatch(trimmed);
    if (range != null) {
      final from = int.parse(range.group(1)!);
      final to = int.parse(range.group(2)!);
      // A reversed range is a typo, not an empty set: honouring the intent beats scanning nothing.
      final low = from <= to ? from : to;
      final high = from <= to ? to : from;
      // Bounded so a fat-fingered `1-65535` cannot queue a scan that never visibly finishes.
      if (high - low > maxPortsPerScan) continue;
      for (var port = low; port <= high; port++) {
        if (port >= 1 && port <= 65535) ports.add(port);
      }
      continue;
    }

    final single = int.tryParse(trimmed);
    if (single != null && single >= 1 && single <= 65535) ports.add(single);
  }
  return ports.toList()..sort();
}

/// The most ports one scan will probe.
const maxPortsPerScan = 1024;

// ── subnets ───────────────────────────────────────────────────────────────────

/// The `/24` containing [address], as the first three octets (`192.168.1`).
String? subnetPrefixOf(String address) {
  final parts = address.split('.');
  if (parts.length != 4) return null;
  for (final part in parts) {
    final octet = int.tryParse(part);
    if (octet == null || octet < 0 || octet > 255) return null;
  }
  return parts.take(3).join('.');
}

/// Every host address in a `/24`, excluding the network and broadcast addresses.
///
/// `.0` and `.255` are skipped because neither is a host — probing them wastes two round trips and
/// a reply from `.255` would be a broadcast echo, not a device.
List<String> hostsInSubnet(String prefix) => [
  for (var host = 1; host <= 254; host++) '$prefix.$host',
];

/// The broadcast address of a `/24`, which is where a magic packet has to go.
String broadcastFor(String prefix) => '$prefix.255';

// ── DNS ───────────────────────────────────────────────────────────────────────

/// The record types offered.
const dnsRecordTypes = ['A', 'AAAA', 'CNAME', 'MX', 'NS', 'TXT'];

/// Wire values for [dnsRecordTypes].
int dnsTypeCode(String type) => switch (type.toUpperCase()) {
  'A' => 1,
  'NS' => 2,
  'CNAME' => 5,
  'MX' => 15,
  'TXT' => 16,
  'AAAA' => 28,
  _ => 1,
};

String dnsTypeName(int code) => switch (code) {
  1 => 'A',
  2 => 'NS',
  5 => 'CNAME',
  15 => 'MX',
  16 => 'TXT',
  28 => 'AAAA',
  _ => 'TYPE$code',
};

/// One answer from a DNS response.
class DnsRecord {
  const DnsRecord({required this.name, required this.type, required this.ttl, required this.value});

  final String name;
  final String type;
  final int ttl;
  final String value;
}

/// Raised for a response that cannot be trusted.
class DnsException implements Exception {
  const DnsException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Builds a standard recursive query for [name].
///
/// [transactionId] is the caller's; the response must echo it back, which is the only cheap defence
/// against accepting an answer that was not a reply to this question.
Uint8List buildDnsQuery(String name, int type, {int transactionId = 0x1234}) {
  // Trimmed per label: a name pasted with stray spaces would otherwise be encoded with them, and
  // the server would answer about a name the user did not type.
  final labels = name.split('.').map((l) => l.trim()).where((l) => l.isNotEmpty).toList();
  if (labels.isEmpty) throw const DnsException('Enter a name to look up.');
  for (final label in labels) {
    // 63 is the wire limit for one label. Silently truncating would query a different name than the
    // one the user typed and report its answers as theirs.
    if (label.length > 63) throw const DnsException('That name has a label over 63 characters.');
  }

  final out = BytesBuilder();
  out.add([
    (transactionId >> 8) & 0xFF, transactionId & 0xFF,
    0x01, 0x00, // standard query, recursion desired
    0x00, 0x01, // one question
    0x00, 0x00, // no answers
    0x00, 0x00, // no authority records
    0x00, 0x00, // no additional records
  ]);
  for (final label in labels) {
    final bytes = utf8.encode(label);
    out
      ..addByte(bytes.length)
      ..add(bytes);
  }
  out
    ..addByte(0) // root label ends the name
    ..add([(type >> 8) & 0xFF, type & 0xFF])
    ..add([0x00, 0x01]); // class IN
  return out.toBytes();
}

/// Parses a DNS response into its answer records.
///
/// Rejects a response whose transaction id does not match the query when [expectTransactionId] is
/// given, and reports the server's own error codes rather than presenting them as "no records" —
/// NXDOMAIN and a timeout are different facts, and only one of them means the name is wrong.
List<DnsRecord> parseDnsResponse(Uint8List data, {int? expectTransactionId}) {
  if (data.length < 12) throw const DnsException('The DNS reply was truncated.');
  final view = ByteData.sublistView(data);

  final id = view.getUint16(0);
  if (expectTransactionId != null && id != expectTransactionId) {
    throw const DnsException('The DNS reply did not match the query that was sent.');
  }

  final flags = view.getUint16(2);
  final responseCode = flags & 0x0F;
  if (responseCode != 0) {
    throw DnsException(switch (responseCode) {
      1 => 'The server rejected the query as malformed.',
      2 => 'The server failed to process the query.',
      3 => 'No such name.',
      4 => 'The server does not support this query type.',
      5 => 'The server refused the query.',
      _ => 'The server returned error code $responseCode.',
    });
  }

  final questionCount = view.getUint16(4);
  final answerCount = view.getUint16(6);

  var offset = 12;
  for (var i = 0; i < questionCount; i++) {
    offset = _skipName(data, offset);
    offset += 4; // qtype + qclass
  }

  final records = <DnsRecord>[];
  for (var i = 0; i < answerCount && offset < data.length; i++) {
    final (name, afterName) = _readName(data, offset);
    offset = afterName;
    if (offset + 10 > data.length) break;

    final type = view.getUint16(offset);
    final ttl = view.getUint32(offset + 4);
    final length = view.getUint16(offset + 8);
    offset += 10;
    if (offset + length > data.length) break;

    records.add(
      DnsRecord(
        name: name,
        type: dnsTypeName(type),
        ttl: ttl,
        value: _readRecordValue(data, offset, length, type),
      ),
    );
    offset += length;
  }
  return records;
}

String _readRecordValue(Uint8List data, int offset, int length, int type) {
  switch (type) {
    case 1: // A
      if (length != 4) return '';
      return data.sublist(offset, offset + 4).join('.');
    case 28: // AAAA
      if (length != 16) return '';
      return [
        for (var i = 0; i < 16; i += 2)
          ((data[i + offset] << 8) | data[i + offset + 1]).toRadixString(16),
      ].join(':');
    case 15: // MX — a two-byte preference, then the exchange name
      if (length < 3) return '';
      final preference = (data[offset] << 8) | data[offset + 1];
      final (exchange, _) = _readName(data, offset + 2);
      return '$preference $exchange';
    case 16: // TXT — one or more length-prefixed strings, concatenated
      final parts = <String>[];
      var cursor = offset;
      while (cursor < offset + length && cursor < data.length) {
        final size = data[cursor];
        cursor++;
        if (cursor + size > data.length) break;
        parts.add(utf8.decode(data.sublist(cursor, cursor + size), allowMalformed: true));
        cursor += size;
      }
      return parts.join();
    case 2: // NS
    case 5: // CNAME
      final (name, _) = _readName(data, offset);
      return name;
    default:
      return '';
  }
}

/// Reads a possibly-compressed name, returning it and the offset just past it.
///
/// DNS compresses repeated names into a pointer to an earlier offset. A malformed or hostile
/// response can point in a loop, so the number of jumps is capped — without that, parsing a reply
/// from an untrusted resolver could hang the app.
(String, int) _readName(Uint8List data, int start) {
  final labels = <String>[];
  var offset = start;
  var afterPointer = -1;
  var jumps = 0;

  while (offset < data.length) {
    final length = data[offset];
    if (length == 0) {
      offset++;
      break;
    }
    if (length & 0xC0 == 0xC0) {
      if (offset + 1 >= data.length) break;
      if (afterPointer < 0) afterPointer = offset + 2;
      offset = ((length & 0x3F) << 8) | data[offset + 1];
      if (++jumps > 20) break;
      continue;
    }
    offset++;
    if (offset + length > data.length) break;
    labels.add(utf8.decode(data.sublist(offset, offset + length), allowMalformed: true));
    offset += length;
  }
  return (labels.join('.'), afterPointer >= 0 ? afterPointer : offset);
}

int _skipName(Uint8List data, int start) => _readName(data, start).$2;

/// Public resolvers used when the platform's own is not reachable from Dart.
///
/// Two, from different operators: one being unreachable is common on a locked-down network, and
/// falling back to a second is the difference between "DNS is broken" and one provider being
/// blocked.
const fallbackResolvers = ['1.1.1.1', '8.8.8.8'];
