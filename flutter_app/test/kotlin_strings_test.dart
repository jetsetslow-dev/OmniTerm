import 'package:flutter_test/flutter_test.dart';
import 'package:omniterm/data/kotlin_strings.dart';

/// The parsers are a line-by-line port of Kotlin, so these helpers have to match Kotlin's semantics
/// exactly — especially at the edges, which is precisely where a parser's tolerance for malformed
/// remote output lives.
void main() {
  group('splitWhitespace with a limit', () {
    test('leaves the remainder unsplit in the final element', () {
      // This is what lets `ps` keep a command containing spaces in one field.
      expect(
        splitWhitespace('1 root 0:00 /sbin/init --verbose splash', limit: 4),
        ['1', 'root', '0:00', '/sbin/init --verbose splash'],
      );
    });

    test('a limit larger than the field count returns every field', () {
      expect(splitWhitespace('a b c', limit: 8), ['a', 'b', 'c']);
    });

    test('limit 1 returns the whole string', () {
      expect(splitWhitespace('a b c', limit: 1), ['a b c']);
    });

    test('limit 0 or negative means unlimited, as in Kotlin', () {
      expect(splitWhitespace('a b c'), ['a', 'b', 'c']);
      expect(splitWhitespace('a b c', limit: -1), ['a', 'b', 'c']);
    });

    test('runs of whitespace collapse to one separator', () {
      expect(splitWhitespace('a    b\t\tc'), ['a', 'b', 'c']);
    });

    test('an empty string yields one empty field', () {
      expect(splitWhitespace(''), ['']);
      expect(splitWhitespace('', limit: 3), ['']);
    });

    test('the remainder keeps its internal whitespace verbatim', () {
      expect(splitWhitespace('a b   c   d', limit: 2), ['a', 'b   c   d']);
    });
  });

  group('string helpers', () {
    test('takeChars never throws on a short string', () {
      expect('abc'.takeChars(12), 'abc');
      expect('abcdefghijklmno'.takeChars(12), 'abcdefghijkl');
      expect(''.takeChars(5), '');
    });

    test('removePrefix / removeSuffix are no-ops when absent', () {
      expect('sha256:abc'.removePrefix('sha256:'), 'abc');
      expect('abc'.removePrefix('sha256:'), 'abc');
      expect('ssh.service'.removeSuffix('.service'), 'ssh');
      expect('ssh'.removeSuffix('.service'), 'ssh');
    });

    test('substringAfter returns the whole string when the delimiter is absent', () {
      expect('2026-05-30T10:41:22'.substringAfter('T'), '10:41:22');
      expect('no-delimiter'.substringAfter('T'), 'no-delimiter');
      expect('a/b'.substringAfter('/', ''), 'b');
      expect('ab'.substringAfter('/', ''), '');
    });

    test('substringBefore and substringBeforeLast pick the right occurrence', () {
      expect('sshd[123]'.substringBefore('['), 'sshd');
      expect('sshd'.substringBefore('['), 'sshd');
      expect('/srv/stacks/app/compose.yml'.substringBeforeLast('/'), '/srv/stacks/app');
      expect('/compose.yml'.substringBeforeLast('/'), '');
    });

    test('ifBlank checks whitespace, ifEmpty checks length', () {
      expect('   '.ifBlank('fallback'), 'fallback');
      expect('   '.ifEmpty('fallback'), '   ', reason: 'whitespace is not empty');
      expect(''.ifEmpty('fallback'), 'fallback');
      expect('x'.ifBlank('fallback'), 'x');
    });

    test('lines splits on all three line endings', () {
      expect('a\nb\r\nc\rd'.lines, ['a', 'b', 'c', 'd']);
    });
  });

  group('list helpers', () {
    test('getOrNull and getOrElse stay in bounds', () {
      final list = ['a', 'b'];
      expect(list.getOrNull(0), 'a');
      expect(list.getOrNull(5), isNull);
      expect(list.getOrNull(-1), isNull);
      expect(list.getOrElse(5, 'z'), 'z');
    });

    test('distinctBy keeps the first match and preserves order', () {
      final items = [(1, 'a'), (2, 'b'), (3, 'a'), (4, 'c')];
      expect(
        items.distinctBy((e) => e.$2).map((e) => e.$1).toList(),
        [1, 2, 4],
      );
    });
  });
}
