/// Display-width rules for terminal cells, ported from the Unicode helpers in
/// `data/term/TerminalEmulator.kt`.
///
/// ## The one thing that could not be ported directly
///
/// The Kotlin asked the JVM for a code point's Unicode general category
/// (`Character.getType` ⇒ `NON_SPACING_MARK` / `COMBINING_SPACING_MARK` / `ENCLOSING_MARK`) to
/// decide that a mark occupies zero columns. **Dart ships no Unicode category database**, so that
/// lookup is replaced by the explicit [_combiningRanges] table below — which is what wcwidth
/// implementations have always done.
///
/// The table is a *bounded* subset, and that matches the documented contract:
/// `docs/TERMINAL_COMPATIBILITY.md` already states "Unicode width remains a bounded terminal subset
/// rather than a shaping engine for every complex script". It covers the combining ranges that
/// appear in terminal output — Latin/Greek/Cyrillic marks, Hebrew/Arabic points, the Indic and
/// South-East Asian ranges, and the emoji modifier machinery — rather than every assigned mark.
library;

const _asciiFirst = 0x20;
const _asciiLast = 0x7E;

/// Zero-width combining marks (Unicode categories Mn, Mc, Me), as inclusive ranges.
///
/// Kept sorted so [_inRanges] can binary-search. Deliberately conservative: a code point wrongly
/// listed here would be *swallowed* into the previous cell, which is far more visible than one
/// wrongly omitted (that merely takes a column of its own).
const List<(int, int)> _combiningRanges = [
  (0x0300, 0x036F), // Combining Diacritical Marks
  (0x0483, 0x0489), // Cyrillic
  (0x0591, 0x05BD), // Hebrew points
  (0x05BF, 0x05BF),
  (0x05C1, 0x05C2),
  (0x05C4, 0x05C5),
  (0x05C7, 0x05C7),
  (0x0610, 0x061A), // Arabic
  (0x064B, 0x065F),
  (0x0670, 0x0670),
  (0x06D6, 0x06DC),
  (0x06DF, 0x06E4),
  (0x06E7, 0x06E8),
  (0x06EA, 0x06ED),
  (0x0711, 0x0711), // Syriac
  (0x0730, 0x074A),
  (0x07A6, 0x07B0), // Thaana
  (0x07EB, 0x07F3), // NKo
  (0x0816, 0x0819), // Samaritan
  (0x081B, 0x0823),
  (0x0825, 0x0827),
  (0x0829, 0x082D),
  (0x0859, 0x085B),
  (0x08E3, 0x0903), // Arabic extended + Devanagari
  (0x093A, 0x093C),
  (0x093E, 0x094F),
  (0x0951, 0x0957),
  (0x0962, 0x0963),
  (0x0981, 0x0983), // Bengali
  (0x09BC, 0x09BC),
  (0x09BE, 0x09CD),
  (0x09D7, 0x09D7),
  (0x09E2, 0x09E3),
  (0x0A01, 0x0A03), // Gurmukhi
  (0x0A3C, 0x0A51),
  (0x0A70, 0x0A71),
  (0x0A75, 0x0A75),
  (0x0A81, 0x0A83), // Gujarati
  (0x0ABC, 0x0ACD),
  (0x0AE2, 0x0AE3),
  (0x0B01, 0x0B03), // Oriya
  (0x0B3C, 0x0B57),
  (0x0B62, 0x0B63),
  (0x0B82, 0x0B82), // Tamil
  (0x0BBE, 0x0BCD),
  (0x0BD7, 0x0BD7),
  (0x0C00, 0x0C03), // Telugu
  (0x0C3E, 0x0C56),
  (0x0C62, 0x0C63),
  (0x0C81, 0x0C83), // Kannada
  (0x0CBC, 0x0CD6),
  (0x0CE2, 0x0CE3),
  (0x0D01, 0x0D03), // Malayalam
  (0x0D3E, 0x0D4D),
  (0x0D57, 0x0D57),
  (0x0D62, 0x0D63),
  (0x0D82, 0x0D83), // Sinhala
  (0x0DCA, 0x0DDF),
  (0x0DF2, 0x0DF3),
  (0x0E31, 0x0E31), // Thai
  (0x0E34, 0x0E3A),
  (0x0E47, 0x0E4E),
  (0x0EB1, 0x0EB1), // Lao
  (0x0EB4, 0x0EBC),
  (0x0EC8, 0x0ECD),
  (0x0F18, 0x0F19), // Tibetan
  (0x0F35, 0x0F35),
  (0x0F37, 0x0F37),
  (0x0F39, 0x0F39),
  (0x0F3E, 0x0F3F),
  (0x0F71, 0x0F84),
  (0x0F86, 0x0F87),
  (0x0F8D, 0x0FBC),
  (0x0FC6, 0x0FC6),
  (0x102B, 0x103E), // Myanmar
  (0x1056, 0x1059),
  (0x105E, 0x1060),
  (0x1062, 0x1064),
  (0x1067, 0x106D),
  (0x1071, 0x1074),
  (0x1082, 0x108D),
  (0x108F, 0x108F),
  (0x109A, 0x109D),
  (0x135D, 0x135F), // Ethiopic
  (0x1712, 0x1714), // Philippine scripts
  (0x1732, 0x1734),
  (0x1752, 0x1753),
  (0x1772, 0x1773),
  (0x17B4, 0x17D3), // Khmer
  (0x17DD, 0x17DD),
  (0x180B, 0x180D), // Mongolian
  (0x1885, 0x1886),
  (0x18A9, 0x18A9),
  (0x1920, 0x193B), // Limbu
  (0x1A17, 0x1A1B), // Buginese
  (0x1A55, 0x1A7F), // Tai Tham
  (0x1AB0, 0x1AFF), // Combining Diacritical Marks Extended
  (0x1B00, 0x1B04), // Balinese
  (0x1B34, 0x1B44),
  (0x1B6B, 0x1B73),
  (0x1B80, 0x1B82), // Sundanese
  (0x1BA1, 0x1BAD),
  (0x1BE6, 0x1BF3), // Batak
  (0x1C24, 0x1C37), // Lepcha
  (0x1CD0, 0x1CE8), // Vedic
  (0x1CED, 0x1CED),
  (0x1CF4, 0x1CF4),
  (0x1CF8, 0x1CF9),
  (0x1DC0, 0x1DFF), // Combining Diacritical Marks Supplement
  (0x20D0, 0x20F0), // Combining Diacritical Marks for Symbols
  (0x2CEF, 0x2CF1), // Coptic
  (0x2D7F, 0x2D7F),
  (0x2DE0, 0x2DFF), // Cyrillic Extended-A
  (0x302A, 0x302F), // CJK tone marks
  (0x3099, 0x309A), // Kana voicing marks
  (0xA66F, 0xA672),
  (0xA674, 0xA67D),
  (0xA69E, 0xA69F),
  (0xA6F0, 0xA6F1),
  (0xA802, 0xA802),
  (0xA806, 0xA806),
  (0xA80B, 0xA80B),
  (0xA823, 0xA827),
  (0xA880, 0xA881),
  (0xA8B4, 0xA8C5),
  (0xA8E0, 0xA8F1),
  (0xA926, 0xA92D),
  (0xA947, 0xA953),
  (0xA980, 0xA983),
  (0xA9B3, 0xA9C0),
  (0xAA29, 0xAA36),
  (0xAA43, 0xAA43),
  (0xAA4C, 0xAA4D),
  (0xAAB0, 0xAAB0),
  (0xAAB2, 0xAAB4),
  (0xAAB7, 0xAAB8),
  (0xAABE, 0xAABF),
  (0xAAC1, 0xAAC1),
  (0xAAEB, 0xAAEF),
  (0xAAF5, 0xAAF6),
  (0xABE3, 0xABEA),
  (0xABEC, 0xABED),
  (0xFB1E, 0xFB1E),
  (0xFE20, 0xFE2F), // Combining Half Marks
  (0x101FD, 0x101FD),
  (0x10376, 0x1037A),
  (0x10A01, 0x10A0F),
  (0x10A38, 0x10A3F),
  (0x11000, 0x11002), // Brahmi
  (0x11038, 0x11046),
  (0x1107F, 0x11082), // Kaithi
  (0x110B0, 0x110BA),
  (0x11100, 0x11102), // Chakma
  (0x11127, 0x11134),
  (0x11173, 0x11173),
  (0x11180, 0x11182),
  (0x111B3, 0x111C0),
  (0x1122C, 0x11237),
  (0x112DF, 0x112EA),
  (0x11300, 0x11303),
  (0x1133C, 0x1134D),
  (0x11357, 0x11357),
  (0x11362, 0x11374),
  (0x11435, 0x11446),
  (0x114B0, 0x114C3),
  (0x115AF, 0x115C0),
  (0x11630, 0x11640),
  (0x116AB, 0x116B7),
  (0x1171D, 0x1172B),
  (0x11C2F, 0x11C3F),
  (0x16AF0, 0x16AF4),
  (0x16B30, 0x16B36),
  (0x1BC9D, 0x1BC9E),
  (0x1D165, 0x1D169), // Musical symbols
  (0x1D16D, 0x1D172),
  (0x1D17B, 0x1D182),
  (0x1D185, 0x1D18B),
  (0x1D1AA, 0x1D1AD),
  (0x1D242, 0x1D244),
  (0x1DA00, 0x1DA36), // SignWriting
  (0x1DA3B, 0x1DA6C),
  (0x1E000, 0x1E006),
  (0x1E8D0, 0x1E8D6),
  (0x1E944, 0x1E94A),
];

bool _inRanges(int codePoint, List<(int, int)> ranges) {
  var low = 0;
  var high = ranges.length - 1;
  while (low <= high) {
    final mid = (low + high) >> 1;
    final (start, end) = ranges[mid];
    if (codePoint < start) {
      high = mid - 1;
    } else if (codePoint > end) {
      low = mid + 1;
    } else {
      return true;
    }
  }
  return false;
}

/// True for a combining mark (Mn / Mc / Me), which occupies no column of its own.
bool isCombiningMark(int codePoint) => _inRanges(codePoint, _combiningRanges);

/// Columns a single code point occupies: 0 (combining/invisible), 1 (normal) or 2 (wide).
///
/// Ported verbatim from `codePointWidth`, with the JVM category lookup replaced as described above.
int codePointWidth(int codePoint) {
  if (codePoint >= _asciiFirst && codePoint <= _asciiLast) return 1;

  // Zero-width: combining marks, format/bidi controls, Hangul jamo tails, variation selectors,
  // emoji skin-tone modifiers and tag characters.
  if (isCombiningMark(codePoint) ||
      codePoint == 0x00AD ||
      codePoint == 0x061C ||
      (codePoint >= 0x1160 && codePoint <= 0x11FF) ||
      (codePoint >= 0x200B && codePoint <= 0x200F) ||
      (codePoint >= 0x202A && codePoint <= 0x202E) ||
      (codePoint >= 0x2060 && codePoint <= 0x206F) ||
      codePoint == 0xFEFF ||
      codePoint == 0x200D ||
      (codePoint >= 0x1F3FB && codePoint <= 0x1F3FF) ||
      (codePoint >= 0xE0020 && codePoint <= 0xE007F) ||
      (codePoint >= 0xFE00 && codePoint <= 0xFE0F) ||
      (codePoint >= 0xE0100 && codePoint <= 0xE01EF)) {
    return 0;
  }

  // Wide: CJK, fullwidth forms, regional indicators, and the emoji planes.
  if ((codePoint >= 0x1100 && codePoint <= 0x115F) ||
      (codePoint >= 0x2329 && codePoint <= 0x232A) ||
      (codePoint >= 0x2E80 && codePoint <= 0xA4CF) ||
      (codePoint >= 0xAC00 && codePoint <= 0xD7A3) ||
      (codePoint >= 0xF900 && codePoint <= 0xFAFF) ||
      (codePoint >= 0xFE10 && codePoint <= 0xFE19) ||
      (codePoint >= 0xFE30 && codePoint <= 0xFE6F) ||
      (codePoint >= 0xFF00 && codePoint <= 0xFF60) ||
      (codePoint >= 0xFFE0 && codePoint <= 0xFFE6) ||
      (codePoint >= 0x1F1E6 && codePoint <= 0x1F1FF) ||
      (codePoint >= 0x1F300 && codePoint <= 0x1FAFF) ||
      (codePoint >= 0x20000 && codePoint <= 0x3FFFD)) {
    return 2;
  }

  return 1;
}

/// Columns a whole grapheme-like cluster occupies.
///
/// The presentation selectors win over the base character's own width: U+FE0E forces text
/// presentation (one column) and U+FE0F forces emoji presentation (two), which is how a terminal
/// keeps a cluster's cell count matching what the font will actually draw. A keycap (U+20E3) and a
/// two-regional-indicator flag are likewise always two columns.
int clusterDisplayWidth(String text) {
  if (text.isEmpty) return 0;
  final points = text.runes.toList();

  if (points.contains(0xFE0E)) return 1; // explicit text presentation

  var regionalIndicators = 0;
  var forcesEmoji = false;
  for (final point in points) {
    if (point == 0xFE0F || point == 0x20E3) forcesEmoji = true;
    if (point >= 0x1F1E6 && point <= 0x1F1FF) regionalIndicators++;
  }
  if (forcesEmoji || regionalIndicators >= 2) return 2;

  var widest = 0;
  for (final point in points) {
    final width = codePointWidth(point);
    if (width > widest) widest = width;
  }
  return widest < 1 ? 1 : widest;
}
