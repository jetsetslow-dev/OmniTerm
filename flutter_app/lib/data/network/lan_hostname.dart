import 'dart:convert';
import 'dart:typed_data';

/// Pure mDNS/NetBIOS hostname wire formats used by the LAN scanner.
///
/// Every parser read is bounds checked and DNS compression follows at most 16 pointers. These
/// replies come from arbitrary devices on the local network, so malformed input is expected rather
/// than exceptional.
class LanHostnameWire {
  const LanHostnameWire._();

  static const typePtr = 12;
  static const typeNbstat = 0x21;
  static const classIn = 1;

  static Uint8List? buildReversePtrQuery(
    String ip, {
    int transactionId = 0,
    bool unicastResponse = true,
  }) {
    final parts = ip.split('.');
    if (parts.length != 4) return null;
    final octets = parts.map(int.tryParse).toList();
    if (octets.any((value) => value == null || value < 0 || value > 255)) {
      return null;
    }
    final labels = [
      for (final value in octets.reversed) '$value',
      'in-addr',
      'arpa',
    ];
    final out = BytesBuilder()
      ..add(_short(transactionId))
      ..add(const [0, 0, 0, 1, 0, 0, 0, 0, 0, 0]);
    for (final label in labels) {
      final bytes = ascii.encode(label);
      out
        ..addByte(bytes.length)
        ..add(bytes);
    }
    out
      ..addByte(0)
      ..add(_short(typePtr))
      ..add(_short(unicastResponse ? classIn | 0x8000 : classIn));
    return out.takeBytes();
  }

  static String? parsePtrAnswer(Uint8List packet) {
    if (packet.length < 12) return null;
    final cursor = _Cursor(packet)..position = 4;
    final questions = cursor.readShort();
    final answers = cursor.readShort();
    if (questions == null || answers == null) return null;
    cursor.position = 12;
    for (var i = 0; i < questions; i++) {
      if (!cursor.skipName() || !cursor.skip(4)) return null;
    }
    for (var i = 0; i < answers; i++) {
      if (!cursor.skipName()) return null;
      final type = cursor.readShort();
      if (type == null || !cursor.skip(6)) return null;
      final length = cursor.readShort();
      if (length == null) return null;
      final start = cursor.position;
      if (type == typePtr) {
        final name = cursor.readName();
        if (name != null && name.isNotEmpty) return name;
      }
      cursor.position = start + length;
      if (cursor.position > packet.length) return null;
    }
    return null;
  }

  static Uint8List buildNetbiosNodeStatusQuery({int transactionId = 0}) {
    final out = BytesBuilder()
      ..add(_short(transactionId))
      ..add(const [0, 0, 0, 1, 0, 0, 0, 0, 0, 0])
      ..addByte(32);
    final name = Uint8List(16)..first = 0x2a;
    for (final byte in name) {
      out
        ..addByte(0x41 + (byte >> 4))
        ..addByte(0x41 + (byte & 0x0f));
    }
    out
      ..addByte(0)
      ..add(_short(typeNbstat))
      ..add(_short(classIn));
    return out.takeBytes();
  }

  static String? parseNetbiosNodeStatus(Uint8List packet) {
    if (packet.length < 12) return null;
    final cursor = _Cursor(packet)..position = 6;
    final answers = cursor.readShort();
    if (answers == null || answers < 1) return null;
    cursor.position = 12;
    if (!cursor.skipName() || !cursor.skip(4) || !cursor.skipName()) {
      return null;
    }
    if (cursor.readShort() != typeNbstat || !cursor.skip(8)) return null;
    final count = cursor.readByte();
    if (count == null) return null;
    for (var i = 0; i < count; i++) {
      final raw = cursor.readBytes(15);
      final suffix = cursor.readByte();
      final flags = cursor.readShort();
      if (raw == null || suffix == null || flags == null) return null;
      if (suffix == 0 && flags & 0x8000 == 0) {
        final name = ascii
            .decode(raw, allowInvalid: true)
            .replaceAll('\u0000', '')
            .trim();
        if (name.isNotEmpty) return name;
      }
    }
    return null;
  }

  static String normalize(String? candidate, String ip) {
    final name =
        candidate?.trim().replaceFirst(RegExp(r'\.$'), '').trim() ?? '';
    if (name.isEmpty || name.toLowerCase() == ip.toLowerCase()) return '';
    if (name.toLowerCase().endsWith('in-addr.arpa')) return '';
    return name;
  }

  static String prettifyNetbios(String name) =>
      name == name.toUpperCase() ? name.toLowerCase() : name;

  static List<int> _short(int value) => [(value >> 8) & 0xff, value & 0xff];
}

class _Cursor {
  _Cursor(this.bytes);

  final Uint8List bytes;
  int position = 0;

  int? readByte() => position < bytes.length ? bytes[position++] : null;

  int? readShort() {
    final high = readByte();
    final low = readByte();
    return high == null || low == null ? null : (high << 8) | low;
  }

  Uint8List? readBytes(int count) {
    if (position + count > bytes.length) return null;
    final result = Uint8List.sublistView(bytes, position, position + count);
    position += count;
    return result;
  }

  bool skip(int count) {
    if (position + count > bytes.length) return false;
    position += count;
    return true;
  }

  bool skipName() {
    while (true) {
      final length = readByte();
      if (length == null) return false;
      if (length == 0) return true;
      if (length & 0xc0 == 0xc0) return readByte() != null;
      if (!skip(length)) return false;
    }
  }

  String? readName() {
    final labels = <String>[];
    var cursor = position;
    var followed = false;
    var hops = 0;
    while (true) {
      if (cursor >= bytes.length) return null;
      final length = bytes[cursor];
      if (length == 0) {
        if (!followed) position = cursor + 1;
        return labels.isEmpty ? null : labels.join('.');
      }
      if (length & 0xc0 == 0xc0) {
        if (cursor + 1 >= bytes.length || ++hops > 16) return null;
        if (!followed) position = cursor + 2;
        followed = true;
        cursor = ((length & 0x3f) << 8) | bytes[cursor + 1];
        continue;
      }
      if (cursor + 1 + length > bytes.length) return null;
      labels.add(
        ascii.decode(
          Uint8List.sublistView(bytes, cursor + 1, cursor + 1 + length),
          allowInvalid: true,
        ),
      );
      cursor += 1 + length;
    }
  }
}
