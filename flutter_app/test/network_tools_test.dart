import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:omniterm/domain/network_tools.dart';

/// DNS is a format where an off-by-one in a length prefix produces a query the server silently
/// ignores — indistinguishable from "no records" at the UI. These tests work at the byte level for
/// that reason.
void main() {
  group('MAC addresses', () {
    test('every separator people actually paste is accepted', () {
      // A MAC gets copied from a router UI, `ip link`, or a sticker, and each writes it differently.
      const expected = [0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff];
      for (final input in [
        'aa:bb:cc:dd:ee:ff',
        'AA-BB-CC-DD-EE-FF',
        'aabb.ccdd.eeff',
        'aabbccddeeff',
        ' aa:bb:cc:dd:ee:ff ',
      ]) {
        expect(parseMacAddress(input), expected, reason: input);
      }
    });

    test('anything that is not six bytes of hex is refused', () {
      for (final input in ['', 'aa:bb:cc', 'aa:bb:cc:dd:ee:ff:00', 'zz:bb:cc:dd:ee:ff']) {
        expect(parseMacAddress(input), isNull, reason: input);
      }
    });

    test('round-trips through the display form', () {
      expect(formatMacAddress(parseMacAddress('AABBCCDDEEFF')!), 'aa:bb:cc:dd:ee:ff');
    });
  });

  group('the magic packet', () {
    final mac = parseMacAddress('aa:bb:cc:dd:ee:ff')!;

    test('is 102 bytes: six 0xFF then the MAC sixteen times', () {
      // Fixed by the standard — a card in low-power mode scans for exactly this pattern.
      final packet = buildMagicPacket(mac);
      expect(packet, hasLength(102));
      expect(packet.sublist(0, 6), everyElement(0xFF));
      for (var repeat = 0; repeat < 16; repeat++) {
        expect(packet.sublist(6 + repeat * 6, 12 + repeat * 6), mac, reason: 'repeat $repeat');
      }
    });

    test('refuses a MAC of the wrong length rather than sending a dud', () {
      expect(
        () => buildMagicPacket(Uint8List.fromList([1, 2, 3])),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  group('port specs', () {
    test('parses numbers, ranges and both together', () {
      expect(parsePortSpec('22'), [22]);
      expect(parsePortSpec('22,80,443'), [22, 80, 443]);
      expect(parsePortSpec('80-83'), [80, 81, 82, 83]);
      expect(parsePortSpec('22, 80-82 ,443'), [22, 80, 81, 82, 443]);
    });

    test('sorted and de-duplicated, so nothing is probed twice', () {
      expect(parsePortSpec('443,22,443,80-81,80'), [22, 80, 81, 443]);
    });

    test('a stray comma does not lose the rest of the list', () {
      // Failing the whole spec over one typo would be a worse outcome than skipping it.
      expect(parsePortSpec('22,,80'), [22, 80]);
      expect(parsePortSpec('22,abc,80'), [22, 80]);
    });

    test('out-of-range ports are dropped', () {
      expect(parsePortSpec('0,22,65536,70000'), [22]);
    });

    test('a reversed range is read as the range it meant', () {
      expect(parsePortSpec('83-80'), [80, 81, 82, 83]);
    });

    test('an enormous range is refused rather than queued', () {
      // A fat-fingered 1-65535 would start a scan that never visibly finishes.
      expect(parsePortSpec('1-65535'), isEmpty);
      expect(parsePortSpec('1-65535,22'), [22], reason: 'the rest of the spec still counts');
    });

    test('the common list is sane and labelled', () {
      expect(commonPorts, everyElement(inInclusiveRange(1, 65535)));
      expect(commonPorts.toSet().length, commonPorts.length);
      // A bare number tells you nothing; "8006 (Proxmox)" tells you what the machine is.
      expect(portLabel(22), 'SSH');
      expect(portLabel(8006), 'Proxmox');
      expect(portLabel(12345), isNull);
    });
  });

  group('subnets', () {
    test('reads the /24 prefix', () {
      expect(subnetPrefixOf('192.168.1.42'), '192.168.1');
      expect(subnetPrefixOf('10.0.0.1'), '10.0.0');
    });

    test('refuses anything that is not a dotted quad', () {
      for (final input in ['192.168.1', '192.168.1.1.1', 'not.an.ip.addr', '192.168.1.999']) {
        expect(subnetPrefixOf(input), isNull, reason: input);
      }
    });

    test('a sweep covers .1 to .254 and skips network and broadcast', () {
      // Neither is a host: probing them wastes round trips, and a reply from .255 is a broadcast
      // echo rather than a device.
      final hosts = hostsInSubnet('192.168.1');
      expect(hosts, hasLength(254));
      expect(hosts.first, '192.168.1.1');
      expect(hosts.last, '192.168.1.254');
      expect(hosts, isNot(contains('192.168.1.0')));
      expect(hosts, isNot(contains('192.168.1.255')));
    });

    test('the broadcast address is where a magic packet goes', () {
      expect(broadcastFor('192.168.1'), '192.168.1.255');
    });
  });

  group('the DNS query', () {
    test('encodes the header the way a resolver expects', () {
      final query = buildDnsQuery('example.com', 1, transactionId: 0xBEEF);
      expect(query[0], 0xBE);
      expect(query[1], 0xEF);
      expect(query[2], 0x01, reason: 'recursion desired');
      expect(query[3], 0x00);
      expect((query[4] << 8) | query[5], 1, reason: 'exactly one question');
    });

    test('encodes the name as length-prefixed labels ending in a root byte', () {
      final query = buildDnsQuery('example.com', 1);
      final body = query.sublist(12);
      expect(body[0], 7);
      expect(utf8.decode(body.sublist(1, 8)), 'example');
      expect(body[8], 3);
      expect(utf8.decode(body.sublist(9, 12)), 'com');
      expect(body[12], 0, reason: 'the root label terminates the name');
      expect((body[13] << 8) | body[14], 1, reason: 'qtype A');
      expect((body[15] << 8) | body[16], 1, reason: 'class IN');
    });

    test('a trailing dot does not add an empty label', () {
      expect(buildDnsQuery('example.com.', 1), buildDnsQuery('example.com', 1));
    });

    test('an empty name is refused', () {
      expect(() => buildDnsQuery('   ', 1), throwsA(isA<DnsException>()));
      expect(() => buildDnsQuery('...', 1), throwsA(isA<DnsException>()));
    });

    test('an over-long label is refused rather than truncated', () {
      // Truncating would query a different name and report its answers as the user's.
      final long = 'a' * 64;
      expect(() => buildDnsQuery('$long.com', 1), throwsA(isA<DnsException>()));
    });

    test('record types map to their wire codes', () {
      expect(dnsTypeCode('A'), 1);
      expect(dnsTypeCode('aaaa'), 28);
      expect(dnsTypeCode('MX'), 15);
      expect(dnsTypeCode('TXT'), 16);
      expect(dnsTypeCode('NS'), 2);
      expect(dnsTypeCode('CNAME'), 5);
      for (final type in dnsRecordTypes) {
        expect(dnsTypeName(dnsTypeCode(type)), type);
      }
    });
  });

  group('the DNS response', () {
    /// Builds a response with one answer, so the parser is exercised against real wire bytes.
    Uint8List response({
      int id = 0x1234,
      int responseCode = 0,
      required int type,
      required List<int> rdata,
      int ttl = 300,
    }) {
      final out = BytesBuilder()
        ..add([(id >> 8) & 0xFF, id & 0xFF])
        ..add([0x81, 0x80 | responseCode])
        ..add([0x00, 0x01]) // one question
        ..add([0x00, 0x01]) // one answer
        ..add([0x00, 0x00])
        ..add([0x00, 0x00])
        // question: example.com
        ..add([7])
        ..add(utf8.encode('example'))
        ..add([3])
        ..add(utf8.encode('com'))
        ..add([0])
        ..add([(type >> 8) & 0xFF, type & 0xFF])
        ..add([0x00, 0x01])
        // answer: a compression pointer back to the question's name
        ..add([0xC0, 0x0C])
        ..add([(type >> 8) & 0xFF, type & 0xFF])
        ..add([0x00, 0x01])
        ..add([
          (ttl >> 24) & 0xFF,
          (ttl >> 16) & 0xFF,
          (ttl >> 8) & 0xFF,
          ttl & 0xFF,
        ])
        ..add([(rdata.length >> 8) & 0xFF, rdata.length & 0xFF])
        ..add(rdata);
      return out.toBytes();
    }

    test('reads an A record', () {
      final records = parseDnsResponse(response(type: 1, rdata: [93, 184, 216, 34]));
      expect(records.single.type, 'A');
      expect(records.single.value, '93.184.216.34');
      expect(records.single.ttl, 300);
      expect(records.single.name, 'example.com', reason: 'the compression pointer was followed');
    });

    test('reads an AAAA record', () {
      final records = parseDnsResponse(response(
        type: 28,
        rdata: [0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1],
      ));
      expect(records.single.type, 'AAAA');
      expect(records.single.value, '2001:db8:0:0:0:0:0:1');
    });

    test('reads an MX record with its preference', () {
      final rdata = <int>[0x00, 0x0A, 4, ...utf8.encode('mail'), 0xC0, 0x0C];
      final records = parseDnsResponse(response(type: 15, rdata: rdata));
      expect(records.single.value, '10 mail.example.com');
    });

    test('reads a TXT record, joining its chunks', () {
      // TXT is a sequence of length-prefixed strings; treating only the first as the value would
      // silently truncate long SPF and DKIM records.
      final rdata = <int>[5, ...utf8.encode('hello'), 6, ...utf8.encode(' world')];
      final records = parseDnsResponse(response(type: 16, rdata: rdata));
      expect(records.single.value, 'hello world');
    });

    test('reads CNAME and NS as names', () {
      final rdata = <int>[3, ...utf8.encode('www'), 0xC0, 0x0C];
      expect(parseDnsResponse(response(type: 5, rdata: rdata)).single.value, 'www.example.com');
      expect(parseDnsResponse(response(type: 2, rdata: rdata)).single.value, 'www.example.com');
    });

    group('errors are reported as themselves', () {
      test('NXDOMAIN says the name does not exist', () {
        // "No records" and "no such name" are different facts and only one means the input is wrong.
        expect(
          () => parseDnsResponse(response(type: 1, rdata: [1, 2, 3, 4], responseCode: 3)),
          throwsA(isA<DnsException>().having((e) => e.message, 'message', contains('No such name'))),
        );
      });

      test('REFUSED is distinguished from a failure', () {
        expect(
          () => parseDnsResponse(response(type: 1, rdata: [1, 2, 3, 4], responseCode: 5)),
          throwsA(isA<DnsException>().having((e) => e.message, 'message', contains('refused'))),
        );
      });

      test('a truncated reply is refused rather than half-read', () {
        expect(
          () => parseDnsResponse(Uint8List.fromList([1, 2, 3])),
          throwsA(isA<DnsException>()),
        );
      });

      test('a reply for a different query is rejected', () {
        // The echoed transaction id is the only cheap check that this answers the question asked.
        expect(
          () => parseDnsResponse(
            response(type: 1, rdata: [1, 2, 3, 4], id: 0x1111),
            expectTransactionId: 0x2222,
          ),
          throwsA(isA<DnsException>().having((e) => e.message, 'message', contains('did not match'))),
        );
      });

      test('a matching id is accepted', () {
        expect(
          parseDnsResponse(
            response(type: 1, rdata: [1, 2, 3, 4], id: 0x2222),
            expectTransactionId: 0x2222,
          ),
          hasLength(1),
        );
      });
    });

    test('a compression pointer loop terminates instead of hanging', () {
      // A hostile or broken resolver can point a name at itself; without a jump cap the parser
      // would spin forever inside the app.
      final data = BytesBuilder()
        ..add([0x12, 0x34, 0x81, 0x80])
        ..add([0x00, 0x00]) // no questions
        ..add([0x00, 0x01]) // one answer
        ..add([0x00, 0x00])
        ..add([0x00, 0x00])
        ..add([0xC0, 0x0C]); // a pointer to itself
      expect(() => parseDnsResponse(data.toBytes()), returnsNormally);
    });
  });

  test('there is more than one fallback resolver, from different operators', () {
    // One being unreachable on a locked-down network is common; a single fallback would report that
    // as "DNS is broken".
    expect(fallbackResolvers.length, greaterThan(1));
    expect(fallbackResolvers.toSet().length, fallbackResolvers.length);
  });
}
