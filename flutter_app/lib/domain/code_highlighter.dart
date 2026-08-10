enum CodeLanguage { none, yaml, shell }

enum HighlightKind { comment, string, number, key, keyword }

class HighlightToken {
  const HighlightToken(this.start, this.end, this.kind);

  final int start;
  final int end;
  final HighlightKind kind;
}

const int highlightMaxCharsCap = 200000;

CodeLanguage languageForFileName(String name) {
  final lower = name.split('/').last.toLowerCase();
  final dot = lower.lastIndexOf('.');
  final extension = dot < 0 ? '' : lower.substring(dot + 1);
  if (extension == 'yml' || extension == 'yaml') return CodeLanguage.yaml;
  if ({'sh', 'bash', 'zsh'}.contains(extension) ||
      lower == 'dockerfile' ||
      lower.endsWith('.env') ||
      {'conf', 'ini', 'cfg', 'properties'}.contains(extension)) {
    return CodeLanguage.shell;
  }
  return CodeLanguage.none;
}

const _yamlLiterals = {'true', 'false', 'null', 'yes', 'no', 'on', 'off', '~'};
const _shellKeywords = {
  'if',
  'then',
  'else',
  'elif',
  'fi',
  'for',
  'while',
  'do',
  'done',
  'case',
  'esac',
  'function',
  'in',
  'return',
  'export',
  'local',
  'echo',
  'cd',
  'exit',
  'set',
  'source',
};

List<HighlightToken> highlightLine(String line, int base, CodeLanguage language) {
  if (language == CodeLanguage.none || line.isEmpty) return const [];
  final tokens = <HighlightToken>[];
  var index = 0;
  if (language == CodeLanguage.yaml) {
    final indent = line.length - line.trimLeft().length;
    final keyStart = line.startsWith('- ', indent) ? indent + 2 : indent;
    final colon = line.indexOf(':', keyStart);
    if (colon > keyStart && (colon + 1 == line.length || line[colon + 1] == ' ')) {
      tokens.add(HighlightToken(base + keyStart, base + colon, HighlightKind.key));
      index = colon + 1;
    }
  }
  while (index < line.length) {
    final character = line[index];
    if (character == '#' && (index == 0 || line[index - 1] == ' ' || line[index - 1] == '\t')) {
      tokens.add(HighlightToken(base + index, base + line.length, HighlightKind.comment));
      break;
    }
    if (character == '"' || character == "'") {
      final quote = character;
      var end = index + 1;
      while (end < line.length) {
        if (line[end] == r'\' && quote == '"') {
          end += 2;
        } else {
          if (line[end] == quote) {
            end++;
            break;
          }
          end++;
        }
      }
      end = end.clamp(index + 1, line.length);
      tokens.add(HighlightToken(base + index, base + end, HighlightKind.string));
      index = end;
      continue;
    }
    final isNumber =
        _isDigit(character) &&
        (index == 0 || (!_isWord(line[index - 1]) && line[index - 1] != '_'));
    if (isNumber) {
      var end = index + 1;
      while (end < line.length && (_isDigit(line[end]) || line[end] == '.')) {
        end++;
      }
      tokens.add(HighlightToken(base + index, base + end, HighlightKind.number));
      index = end;
      continue;
    }
    if (_isLetter(character)) {
      var end = index + 1;
      while (end < line.length && (_isWord(line[end]) || line[end] == '-')) {
        end++;
      }
      final word = line.substring(index, end);
      final keyword = language == CodeLanguage.yaml
          ? _yamlLiterals.contains(word.toLowerCase())
          : _shellKeywords.contains(word);
      if (keyword) {
        tokens.add(HighlightToken(base + index, base + end, HighlightKind.keyword));
      }
      index = end;
      continue;
    }
    index++;
  }
  return tokens;
}

List<HighlightToken> highlightAll(String text, CodeLanguage language) {
  if (language == CodeLanguage.none) return const [];
  final result = <HighlightToken>[];
  var base = 0;
  for (final line in text.split('\n')) {
    result.addAll(highlightLine(line, base, language));
    base += line.length + 1;
  }
  return result;
}

bool _isDigit(String value) {
  final code = value.codeUnitAt(0);
  return code >= 48 && code <= 57;
}

bool _isLetter(String value) {
  final code = value.codeUnitAt(0);
  return (code >= 65 && code <= 90) || (code >= 97 && code <= 122);
}

bool _isWord(String value) => _isLetter(value) || _isDigit(value) || value == '_';
