import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:omniterm/data/network/lan_hostname.dart';

void main() {
  group('mDNS reverse PTR', () {
    test('query reverses a dotted IPv4 address and requests a unicast reply', () {
      final query = LanHostnameWire.buildReversePtrQuery('192.168.11.5', transactionId: 0x1234)!;
      expect(query.sublist(0, 2), [0x12, 0x34]);
      expect(_shortAt(query, 4), 1);
      final (name, next) = _labels(query, 12);
      expect(name, '5.11.168.192.in-addr.arpa');
      expect(_shortAt(query, next), LanHostnameWire.typePtr);
      expect(_shortAt(query, next + 2), 0x8001);
    });

    test('query rejects anything other than a dotted IPv4 literal', () {
      for (final value in ['', '192.168.1', '192.168.1.999', 'nas.local']) {
        expect(LanHostnameWire.buildReversePtrQuery(value), isNull);
      }
    });

    test('compressed, uncompressed and questionless answers parse', () {
      expect(
        LanHostnameWire.parsePtrAnswer(
          _ptrResponse('nas.local', question: '5.11.168.192.in-addr.arpa', compress: true),
        ),
        'nas.local',
      );
      expect(
        LanHostnameWire.parsePtrAnswer(
          _ptrResponse('printer.local', question: '5.11.168.192.in-addr.arpa'),
        ),
        'printer.local',
      );
      expect(LanHostnameWire.parsePtrAnswer(_ptrResponse('server.local')), 'server.local');
    });

    test('truncation and cyclic compression are rejected without throwing', () {
      final packet = _ptrResponse(
        'nas.local',
        question: '5.11.168.192.in-addr.arpa',
        compress: true,
      );
      for (var cut = 0; cut < packet.length; cut++) {
        expect(
          () => LanHostnameWire.parsePtrAnswer(Uint8List.sublistView(packet, 0, cut)),
          returnsNormally,
        );
      }
      final cyclic = BytesBuilder()
        ..add(_header(questions: 0, answers: 1))
        ..add(const [0])
        ..add(_short(LanHostnameWire.typePtr))
        ..add(_short(LanHostnameWire.classIn))
        ..add(const [0, 0, 0, 120, 0, 2, 0xc0, 0x17]);
      expect(LanHostnameWire.parsePtrAnswer(cyclic.takeBytes()), isNull);
    });
  });

  group('NetBIOS node status', () {
    test('query first-level encodes the wildcard name', () {
      final query = LanHostnameWire.buildNetbiosNodeStatusQuery(transactionId: 0xab);
      expect(query.sublist(0, 2), [0, 0xab]);
      expect(query[12], 32);
      expect(ascii.decode(query.sublist(13, 45)), 'CK${List.filled(30, 'A').join()}');
      expect(_shortAt(query, 46), LanHostnameWire.typeNbstat);
    });

    test('response chooses the unique workstation name, not workgroup or service', () {
      final packet = _netbiosResponse([
        ('WORKGROUP', 0, true),
        ('TARSERVER', 0, false),
        ('TARSERVER', 0x20, false),
      ]);
      expect(LanHostnameWire.parseNetbiosNodeStatus(packet), 'TARSERVER');
      expect(
        LanHostnameWire.parseNetbiosNodeStatus(_netbiosResponse([('TARSERVER', 0x20, false)])),
        isNull,
      );
    });

    test('every truncated response is safe', () {
      final packet = _netbiosResponse([('TARSERVER', 0, false)]);
      for (var cut = 0; cut < packet.length; cut++) {
        expect(
          () => LanHostnameWire.parseNetbiosNodeStatus(Uint8List.sublistView(packet, 0, cut)),
          returnsNormally,
        );
      }
    });
  });

  test('normalization rejects resolver non-answers and prettifies shouted NetBIOS', () {
    expect(LanHostnameWire.normalize(null, '192.168.1.5'), '');
    expect(LanHostnameWire.normalize('192.168.1.5', '192.168.1.5'), '');
    expect(LanHostnameWire.normalize('5.1.168.192.in-addr.arpa', '192.168.1.5'), '');
    expect(LanHostnameWire.normalize(' nas.local. ', '192.168.1.5'), 'nas.local');
    expect(LanHostnameWire.prettifyNetbios('OFFICE-NAS'), 'office-nas');
  });
}

Uint8List _ptrResponse(String answer, {String? question, bool compress = false}) {
  final rdata = BytesBuilder()..add(_encodedName(answer));
  final body = BytesBuilder()..add(_header(questions: question == null ? 0 : 1, answers: 1));
  if (question != null) {
    body
      ..add(_encodedName(question))
      ..add(_short(LanHostnameWire.typePtr))
      ..add(_short(LanHostnameWire.classIn));
  }
  body
    ..add(compress && question != null ? const [0xc0, 0x0c] : const [0])
    ..add(_short(LanHostnameWire.typePtr))
    ..add(_short(LanHostnameWire.classIn))
    ..add(const [0, 0, 0, 120])
    ..add(_short(rdata.length))
    ..add(rdata.takeBytes());
  return body.takeBytes();
}

Uint8List _netbiosResponse(List<(String, int, bool)> names) {
  final encodedName = Uint8List(34)
    ..first = 32
    ..setRange(1, 33, List.filled(32, 0x41));
  final rdata = BytesBuilder()..addByte(names.length);
  for (final (name, suffix, group) in names) {
    rdata
      ..add(ascii.encode(name.padRight(15)).take(15).toList())
      ..addByte(suffix)
      ..add(_short(group ? 0x8000 : 0x0400));
  }
  final out = BytesBuilder()
    ..add(_header(questions: 1, answers: 1))
    ..add(encodedName)
    ..add(_short(LanHostnameWire.typeNbstat))
    ..add(_short(LanHostnameWire.classIn))
    ..add(encodedName)
    ..add(_short(LanHostnameWire.typeNbstat))
    ..add(_short(LanHostnameWire.classIn))
    ..add(const [0, 0, 0, 0])
    ..add(_short(rdata.length))
    ..add(rdata.takeBytes());
  return out.takeBytes();
}

List<int> _header({required int questions, required int answers}) => [
  0,
  0,
  0x84,
  0,
  ..._short(questions),
  ..._short(answers),
  0,
  0,
  0,
  0,
];

Uint8List _encodedName(String name) {
  final out = BytesBuilder();
  for (final label in name.split('.')) {
    final bytes = ascii.encode(label);
    out
      ..addByte(bytes.length)
      ..add(bytes);
  }
  out.addByte(0);
  return out.takeBytes();
}

(String, int) _labels(Uint8List bytes, int start) {
  final labels = <String>[];
  var cursor = start;
  while (bytes[cursor] != 0) {
    final length = bytes[cursor++];
    labels.add(ascii.decode(bytes.sublist(cursor, cursor + length)));
    cursor += length;
  }
  return (labels.join('.'), cursor + 1);
}

int _shortAt(Uint8List bytes, int offset) => (bytes[offset] << 8) | bytes[offset + 1];
List<int> _short(int value) => [(value >> 8) & 0xff, value & 0xff];
