/// Names for the tmux sessions OmniTerm starts, ported from `generateTmuxSessionName`,
/// `generateUniqueTmuxSessionName` and `displayTmuxSessionName` in `ui/ShellSession.kt`.
library;

import 'dart:math';

const _adjectives = [
  'bouncy', 'brisk', 'cheery', 'cozy', 'curious', 'dapper', 'fizzy', 'jolly', //
  'mellow', 'peppy', 'plucky', 'quirky', 'snappy', 'sparkly', 'sunny', 'zippy',
];

const _nouns = [
  'bagel', 'banjo', 'biscuit', 'bubble', 'button', 'cactus', 'cupcake', 'doorknob', //
  'fountain', 'gadget', 'lantern', 'muffin', 'noodle', 'pancake', 'pickle', 'teacup',
];

const _endings = [
  'orbit', 'parade', 'signal', 'sprinkle', 'sunrise', 'tango', 'waffle', 'whistle', //
  'wiggle', 'window', 'wizard', 'zipper', 'marshmallow', 'moonbeam', 'popcorn', 'rainbow',
];

/// `omniterm-` and three friendly words, then a 128-bit token written as the letters a–p (one
/// letter per nibble): readable in tmux's own list, shell-safe, free of digits, and in practice
/// never repeated. [random] makes it repeatable in tests; otherwise the token is from a secure
/// source.
String generateTmuxSessionName([Random? random]) {
  final words = random ?? Random();
  final bytes = random ?? Random.secure();
  final token = StringBuffer();
  for (var i = 0; i < 16; i++) {
    final byte = bytes.nextInt(256);
    token
      ..writeCharCode(0x61 + (byte >> 4))
      ..writeCharCode(0x61 + (byte & 0x0f));
  }
  final phrase = [
    _adjectives[words.nextInt(_adjectives.length)],
    _nouns[words.nextInt(_nouns.length)],
    _endings[words.nextInt(_endings.length)],
  ].join('-');
  return 'omniterm-$phrase-$token';
}

/// A [generateTmuxSessionName] not in [existingNames].
String generateUniqueTmuxSessionName(Set<String> existingNames, [Random? random]) {
  for (var i = 0; i < 128; i++) {
    final candidate = generateTmuxSessionName(random);
    if (!existingNames.contains(candidate)) return candidate;
  }
  // The phrase space is intentionally friendly and finite. This fallback remains number-free and
  // shell-safe while making an in-practice collision impossible if a host has many saved sessions.
  final secure = Random.secure();
  final letters = String.fromCharCodes([for (var i = 0; i < 16; i++) 0x61 + secure.nextInt(6)]);
  return 'omniterm-session-$letters';
}

/// How a session is named on screen: OmniTerm's own sessions by their words alone
/// ("bouncy bagel orbit"); one attached from the host's own list as the user named it.
String displayTmuxSessionName(String tmuxName) => tmuxName
    .replaceFirst(RegExp('^omniterm-'), '')
    .replaceFirst(RegExp(r'-[a-p]{32}$'), '')
    .replaceAll('-', ' ');
