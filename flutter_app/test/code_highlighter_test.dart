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

  test('none produces no tokens', () {
    expect(highlightAll('image: nginx # comment', CodeLanguage.none), isEmpty);
  });

  test('yaml handles comments, quoted fragments, unicode and malformed lines safely', () {
    const source = '''
# leading comment
services:
  web:
    image: "registry.example/a:b#fragment" # real comment
    environment: { FLAG: true, COUNT: 12.5 }
    command: 'unterminated café-東京-🙂
''';
    final tokens = highlightAll(source, CodeLanguage.yaml);

    expect(tokens.every((token) => token.start >= 0 && token.end <= source.length), isTrue);
    expect(
      tokens.any(
        (token) =>
            token.kind == HighlightKind.comment &&
            source.substring(token.start, token.end) == '# leading comment',
      ),
      isTrue,
    );
    expect(
      tokens.any(
        (token) =>
            token.kind == HighlightKind.string &&
            source.substring(token.start, token.end).contains('a:b#fragment'),
      ),
      isTrue,
    );
    expect(
      tokens.any(
        (token) =>
            token.kind == HighlightKind.number &&
            source.substring(token.start, token.end) == '12.5',
      ),
      isTrue,
    );
  });

  test('shell highlighting distinguishes fragments from real comments at a nonzero base', () {
    const line = r'''if [ "$URL" ]; then echo "a\"#b" foo#bar # comment; fi''';
    final tokens = highlightLine(line, 17, CodeLanguage.shell);

    expect(tokens.every((token) => token.start >= 17 && token.end <= line.length + 17), isTrue);
    String text(HighlightToken token) => line.substring(token.start - 17, token.end - 17);
    expect(
      tokens.any((token) => token.kind == HighlightKind.keyword && text(token) == 'if'),
      isTrue,
    );
    expect(
      tokens.any(
        (token) => token.kind == HighlightKind.comment && text(token).startsWith('# comment'),
      ),
      isTrue,
    );
    expect(
      tokens.where((token) => token.kind == HighlightKind.comment).map(text),
      isNot(contains('#bar # comment; fi')),
    );
  });
}
