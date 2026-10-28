import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:omniterm/domain/tmux_session_name.dart';

/// As Kotlin's `TmuxSessionNameTest`.
void main() {
  test('generated tmux names are readable and shell-safe', () {
    for (var seed = 0; seed < 100; seed++) {
      final name = generateTmuxSessionName(Random(seed));

      expect(name, startsWith('omniterm-'));
      expect(name, matches(RegExp(r'^[a-z-]+$')));
      expect(name, isNot(matches(RegExp(r'\d'))));
      expect(displayTmuxSessionName(name), isNot(contains('omniterm')));
      expect(name.split('-').last, hasLength(32), reason: 'name must carry a 128-bit letter token');
    }
  });

  test('the unique generator skips an existing name', () {
    final first = generateTmuxSessionName(Random(7));

    final next = generateUniqueTmuxSessionName({first}, Random(7));

    expect(next, startsWith('omniterm-'));
    expect(next, matches(RegExp(r'^[a-z-]+$')));
    expect(next, isNot(first));
  });

  test('an injected random makes the generator repeatable', () {
    expect(generateUniqueTmuxSessionName({}, Random(7)), generateTmuxSessionName(Random(7)));
  });

  test('a session is shown by its words, and an adopted one by its own name', () {
    expect(
      displayTmuxSessionName('omniterm-cozy-banjo-tango-${'a' * 16}${'p' * 16}'),
      'cozy banjo tango',
    );
    expect(displayTmuxSessionName('main'), 'main');
    expect(displayTmuxSessionName('build-box'), 'build box');
  });
}
