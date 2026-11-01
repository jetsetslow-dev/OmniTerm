/// Decode the fixture's comma-separated decimal bytes after joining painted terminal rows.
/// Whitespace is unsuitable as a delimiter because snapshots trim blank cells at wrap boundaries.
List<int>? readTerminalFixtureBytes(String output, String token) {
  final escaped = RegExp.escape(token);
  final match = RegExp('KEYBAR_$escaped:([\\d,]+):END_$escaped').firstMatch(output);
  if (match == null) return null;
  return match.group(1)!.split(',').where((value) => value.isNotEmpty).map(int.parse).toList();
}
