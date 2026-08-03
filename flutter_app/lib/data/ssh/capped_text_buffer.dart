/// A bounded accumulator for command output, ported from `data/ssh/CappedTextBuffer.kt`.
///
/// Long-running remote commands (`docker pull`, a verbose build) can emit far more output than is
/// useful to hold in memory. This keeps the most recent [maxChars] characters and says so, rather
/// than letting a single command exhaust the heap.
class CappedTextBuffer {
  CappedTextBuffer(this.maxChars);

  final int maxChars;
  final StringBuffer _builder = StringBuffer();

  /// Tracked separately from the buffer contents: once output has been dropped, the notice must
  /// keep appearing even if the retained tail later happens to be short.
  bool _truncated = false;

  bool get truncated => _truncated;

  void append(String value) {
    if (value.isEmpty) return;
    _builder.write(value);
    if (_builder.length > maxChars) {
      // StringBuffer has no delete(); rebuild from the retained tail.
      final tail = _builder.toString();
      final kept = tail.substring(tail.length - maxChars);
      _builder
        ..clear()
        ..write(kept);
      _truncated = true;
    }
  }

  String text() {
    final value = _builder.toString();
    return _truncated
        ? '[Output truncated; showing latest $maxChars characters]\n$value'
        : value;
  }

  bool isBlank() => _builder.toString().trim().isEmpty;
}
