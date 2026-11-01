/// PBKDF2 with HMAC-SHA256, the key derivation behind the app PIN and the backup passphrase.
///
/// Kotlin derives both with `javax.crypto`'s PBKDF2WithHmacSHA256. `package:cryptography`'s
/// `Pbkdf2` gives the same bytes but rebuilds the HMAC key state on every round: four SHA-256
/// blocks and fresh buffers per round where two blocks will do. In a release build on the API 35
/// emulator a PIN (210,000 rounds) took 1.9 s against Kotlin's 0.38 s, and a backup key (600,000)
/// 5.4 s against 1.06 s. Pointycastle's PBKDF2 was slower still.
///
/// This computes the inner and outer key states once, so each round is two compressions over
/// reused buffers: 0.30 s and 0.85 s on the same emulator. `test/pbkdf2_test.dart` pins it to the
/// RFC 7914 vectors and to `package:cryptography`'s output.
library;

import 'dart:typed_data';

/// The [length]-byte PBKDF2-HMAC-SHA256 key for [password] and [salt] after [iterations] rounds.
Uint8List pbkdf2HmacSha256(List<int> password, List<int> salt, int iterations, int length) {
  final w = Uint32List(64);
  var key = password;
  if (key.length > _blockBytes) {
    final digest = Uint32List.fromList(_initialState);
    _absorb(digest, w, key, 0);
    key = _bytes(digest);
  }
  final innerKey = _keyState(key, 0x36, w);
  final outerKey = _keyState(key, 0x5c, w);

  final out = Uint8List(length);
  final saltAndIndex = Uint8List(salt.length + 4)..setAll(0, salt);
  final inner = Uint32List(8);
  final u = Uint32List(8);
  final t = Uint32List(8);
  for (var block = 1, offset = 0; offset < length; block++, offset += _digestBytes) {
    ByteData.sublistView(saltAndIndex).setUint32(salt.length, block);
    inner.setAll(0, innerKey);
    _absorb(inner, w, saltAndIndex, _blockBytes);
    _hashDigest(u, outerKey, inner, w);
    t.setAll(0, u);
    for (var i = 1; i < iterations; i++) {
      _hashDigest(inner, innerKey, u, w);
      _hashDigest(u, outerKey, inner, w);
      for (var j = 0; j < 8; j++) {
        t[j] ^= u[j];
      }
    }
    final end = offset + _digestBytes < length ? offset + _digestBytes : length;
    out.setRange(offset, end, _bytes(t));
  }
  return out;
}

const _blockBytes = 64;
const _digestBytes = 32;

/// SHA-256 state after one block of the HMAC key XORed with [pad].
Uint32List _keyState(List<int> key, int pad, Uint32List w) {
  final block = Uint8List(_blockBytes)..fillRange(0, _blockBytes, pad);
  for (var i = 0; i < key.length; i++) {
    block[i] ^= key[i];
  }
  final state = Uint32List.fromList(_initialState);
  _compressBytes(state, w, block, 0);
  return state;
}

/// Sets [into] to the SHA-256 of a key block, whose state is [from], followed by [digest].
void _hashDigest(Uint32List into, Uint32List from, Uint32List digest, Uint32List w) {
  for (var i = 0; i < 8; i++) {
    w[i] = digest[i];
  }
  w[8] = 0x80000000;
  for (var i = 9; i < 15; i++) {
    w[i] = 0;
  }
  w[15] = (_blockBytes + _digestBytes) * 8;
  into.setAll(0, from);
  _compress(into, w);
}

/// Runs [data] and the final padding through [state], as the rest of a message whose first
/// [prefixLength] bytes it has already taken.
void _absorb(Uint32List state, Uint32List w, List<int> data, int prefixLength) {
  final padded = Uint8List((data.length + 9 + 63) & ~63)..setAll(0, data);
  padded[data.length] = 0x80;
  final bits = (prefixLength + data.length) * 8;
  final view = ByteData.sublistView(padded);
  view.setUint32(padded.length - 8, bits ~/ 0x100000000);
  view.setUint32(padded.length - 4, bits & 0xffffffff);
  for (var offset = 0; offset < padded.length; offset += _blockBytes) {
    _compressBytes(state, w, padded, offset);
  }
}

void _compressBytes(Uint32List state, Uint32List w, Uint8List data, int offset) {
  final view = ByteData.sublistView(data);
  for (var i = 0; i < 16; i++) {
    w[i] = view.getUint32(offset + i * 4);
  }
  _compress(state, w);
}

Uint8List _bytes(Uint32List words) {
  final bytes = Uint8List(words.length * 4);
  final view = ByteData.sublistView(bytes);
  for (var i = 0; i < words.length; i++) {
    view.setUint32(i * 4, words[i]);
  }
  return bytes;
}

@pragma('vm:prefer-inline')
int _rotr(int x, int n) => ((x >> n) | (x << (32 - n))) & 0xffffffff;

/// The SHA-256 compression function (FIPS 180-4 §6.2.2) over the block in `w[0..15]`.
void _compress(Uint32List state, Uint32List w) {
  for (var i = 16; i < 64; i++) {
    final a = w[i - 15];
    final b = w[i - 2];
    w[i] =
        w[i - 16] +
        (_rotr(a, 7) ^ _rotr(a, 18) ^ (a >> 3)) +
        w[i - 7] +
        (_rotr(b, 17) ^ _rotr(b, 19) ^ (b >> 10));
  }
  var a = state[0], b = state[1], c = state[2], d = state[3];
  var e = state[4], f = state[5], g = state[6], h = state[7];
  for (var i = 0; i < 64; i++) {
    final t1 =
        (h +
            (_rotr(e, 6) ^ _rotr(e, 11) ^ _rotr(e, 25)) +
            ((e & f) ^ (~e & g)) +
            _roundConstants[i] +
            w[i]) &
        0xffffffff;
    final t2 =
        ((_rotr(a, 2) ^ _rotr(a, 13) ^ _rotr(a, 22)) + ((a & b) ^ (a & c) ^ (b & c))) & 0xffffffff;
    h = g;
    g = f;
    f = e;
    e = (d + t1) & 0xffffffff;
    d = c;
    c = b;
    b = a;
    a = (t1 + t2) & 0xffffffff;
  }
  state[0] += a;
  state[1] += b;
  state[2] += c;
  state[3] += d;
  state[4] += e;
  state[5] += f;
  state[6] += g;
  state[7] += h;
}

const _initialState = <int>[
  0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19, //
];

const _roundConstants = <int>[
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5, //
  0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174, //
  0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da, //
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967, //
  0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, //
  0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070, //
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3, //
  0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2, //
];
