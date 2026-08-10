import 'package:flutter_test/flutter_test.dart';
import 'package:omniterm/domain/code_highlighter.dart';

void main() {
  test('file names select the same lightweight languages as Kotlin', () {
    expect(languageForFileName('compose.yaml'), CodeLanguage.yaml);
    expect(languageForFileName('/tmp/tool.sh'), CodeLanguage.shell);
    expect(languageForFileName('Dockerfile'), CodeLanguage.shell);
    expect(languageForFileName('app.conf'), CodeLanguage.shell);
    expect(languageForFileName('notes.txt'), CodeLanguage.none);
  });

  test('yaml keys, literals, numbers, strings and comments are tokenized', () {
    final tokens = highlightAll(
      'enabled: true\nport: 8080 # public\nname: "web"',
      CodeLanguage.yaml,
    );
    expect(tokens.where((token) => token.kind == HighlightKind.key), hasLength(3));
    expect(tokens.where((token) => token.kind == HighlightKind.keyword), hasLength(1));
    expect(tokens.where((token) => token.kind == HighlightKind.number), hasLength(1));
    expect(tokens.where((token) => token.kind == HighlightKind.comment), hasLength(1));
    expect(tokens.where((token) => token.kind == HighlightKind.string), hasLength(1));
  });

  test('a hash inside a value is not mistaken for a comment', () {
    final tokens = highlightLine('url=https://host/#fragment', 0, CodeLanguage.shell);
    expect(tokens.where((token) => token.kind == HighlightKind.comment), isEmpty);
  });

  test('unterminated strings stay within the line', () {
    final tokens = highlightLine('echo "unfinished', 10, CodeLanguage.shell);
    final string = tokens.singleWhere((token) => token.kind == HighlightKind.string);
    expect(string.start, 15);
    expect(string.end, 26);
  });
}
