import '../data/term/terminal_snapshot.dart';

final RegExp _terminalUrl = RegExp(
  r'''(?:https?://|www\.)[^\s'"<>()\[\]{}]+''',
  caseSensitive: false,
);

/// The URL occupying [textOffset] in a logical terminal line.
String? terminalLinkAt(String line, int textOffset) {
  for (final match in _terminalUrl.allMatches(line)) {
    if (textOffset < match.start || textOffset >= match.end) continue;
    final value = match.group(0)!.replaceFirst(RegExp(r'[.,;:!?]+$'), '');
    if (textOffset >= match.start + value.length) return null;
    return value.toLowerCase().startsWith('www.') ? 'https://$value' : value;
  }
  return null;
}

/// Rebuilds the logical line containing [rowIndex], joining terminal soft wraps.
({String text, int rowOffset})? logicalTerminalLine(List<TermRow> rows, int rowIndex) {
  if (rowIndex < 0 || rowIndex >= rows.length) return null;
  var first = rowIndex;
  while (first > 0 && rows[first - 1].softWrap) {
    first--;
  }
  var last = rowIndex;
  while (last < rows.length - 1 && rows[last].softWrap) {
    last++;
  }
  final buffer = StringBuffer();
  var offset = 0;
  for (var i = first; i <= last; i++) {
    if (i == rowIndex) offset = buffer.length;
    buffer.write(rows[i].text);
  }
  return (text: buffer.toString(), rowOffset: offset);
}

/// Maps a painted terminal cell to the UTF-16 text offset used by Dart strings and regexes.
int terminalColumnToTextOffset(TermRow row, int column) {
  var cell = 0;
  var text = 0;
  for (final span in row.spans) {
    if (span.glyphs.isNotEmpty && span.glyphWidths.length == span.glyphs.length) {
      for (var i = 0; i < span.glyphs.length; i++) {
        final width = span.glyphWidths[i].clamp(1, 2);
        if (column < cell + width) return text;
        cell += width;
        text += span.glyphs[i].length;
      }
      continue;
    }
    for (final rune in span.text.runes) {
      if (column <= cell) return text;
      cell++;
      text += rune > 0xffff ? 2 : 1;
    }
  }
  return text;
}

String? terminalLinkAtCell(TerminalSnapshot snapshot, int row, int column) {
  if (row < 0 || row >= snapshot.rows.length) return null;
  final logical = logicalTerminalLine(snapshot.rows, row);
  if (logical == null) return null;
  final offset = logical.rowOffset + terminalColumnToTextOffset(snapshot.rows[row], column);
  return terminalLinkAt(logical.text, offset);
}
