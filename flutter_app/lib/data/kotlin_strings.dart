/// Small helpers reproducing Kotlin stdlib string/collection semantics that Dart has no direct
/// equivalent for.
///
/// The parsers in `remote_parsers.dart` are a line-by-line port of Kotlin code whose behaviour on
/// malformed input is load-bearing — it is what keeps a truncated or unexpected `ps`/`df`/`docker`
/// output from throwing mid-poll. Reimplementing these idioms approximately is how that behaviour
/// gets lost, so they are implemented exactly once, here, and tested.
library;

/// Kotlin's `String.split(Regex, limit)`.
///
/// Dart's [String.split] has no limit parameter. Kotlin splits *at most* `limit - 1` times, so the
/// final element holds the unsplit remainder — which is what lets `ps` output keep a command
/// containing spaces in one field. `limit <= 0` means unlimited, as in Kotlin.
List<String> splitWithLimit(String input, RegExp pattern, {int limit = 0}) {
  if (limit <= 0) return input.split(pattern);

  final out = <String>[];
  var rest = input;
  while (out.length < limit - 1) {
    final match = pattern.firstMatch(rest);
    if (match == null) break;
    out.add(rest.substring(0, match.start));
    rest = rest.substring(match.end);
  }
  out.add(rest);
  return out;
}

/// Splits on runs of whitespace, honouring Kotlin's `limit` semantics.
List<String> splitWhitespace(String input, {int limit = 0}) =>
    splitWithLimit(input, RegExp(r'\s+'), limit: limit);

extension KotlinStringOps on String {
  /// Kotlin's `take(n)` — a prefix of at most [n] characters, never throwing.
  String takeChars(int n) => length <= n ? this : substring(0, n);

  /// Kotlin's `removePrefix`: returns the string unchanged when the prefix is absent.
  String removePrefix(String prefix) => startsWith(prefix) ? substring(prefix.length) : this;

  /// Kotlin's `removeSuffix`: returns the string unchanged when the suffix is absent.
  String removeSuffix(String suffix) =>
      endsWith(suffix) && suffix.isNotEmpty ? substring(0, length - suffix.length) : this;

  /// Kotlin's `substringAfter(delimiter, missingDelimiterValue = this)`.
  String substringAfter(String delimiter, [String? missing]) {
    final i = indexOf(delimiter);
    return i < 0 ? (missing ?? this) : substring(i + delimiter.length);
  }

  /// Kotlin's `substringBefore(delimiter, missingDelimiterValue = this)`.
  String substringBefore(String delimiter, [String? missing]) {
    final i = indexOf(delimiter);
    return i < 0 ? (missing ?? this) : substring(0, i);
  }

  /// Kotlin's `substringBeforeLast(delimiter, missingDelimiterValue = this)`.
  String substringBeforeLast(String delimiter, [String? missing]) {
    final i = lastIndexOf(delimiter);
    return i < 0 ? (missing ?? this) : substring(0, i);
  }

  /// Kotlin's `isBlank()` — empty or whitespace only.
  bool get isBlankString => trim().isEmpty;

  /// Kotlin's `ifBlank { fallback }`.
  String ifBlank(String fallback) => isBlankString ? fallback : this;

  /// Kotlin's `ifEmpty { fallback }` — note this checks *empty*, not blank.
  String ifEmpty(String fallback) => isEmpty ? fallback : this;

  /// Kotlin's `lines()` — splits on \n, \r\n and \r.
  List<String> get lines => split(RegExp(r'\r\n|\n|\r'));
}

extension KotlinIterableOps<T> on Iterable<T> {
  /// Kotlin's `firstOrNull` / `lastOrNull`, without throwing on an empty collection.
  ///
  /// Centralised here rather than redeclared per file: three private copies had already appeared,
  /// and divergent copies of a "safe accessor" are how an unsafe one eventually slips in.
  T? get firstOrNull => isEmpty ? null : first;

  T? get lastOrNull => isEmpty ? null : last;
}

extension KotlinListOps<T> on List<T> {
  /// Kotlin's `getOrNull(index)`.
  T? getOrNull(int index) => (index >= 0 && index < length) ? this[index] : null;

  /// Kotlin's `getOrElse(index) { fallback }`.
  T getOrElse(int index, T fallback) => getOrNull(index) ?? fallback;

  /// Kotlin's `distinctBy` — keeps the *first* element for each key, preserving order.
  List<T> distinctBy<K>(K Function(T) selector) {
    final seen = <K>{};
    return [
      for (final item in this)
        if (seen.add(selector(item))) item,
    ];
  }
}
