/// Ported from `data/RemoteParsers.kt`'s `RemoteCommands` object.
///
/// **Partial port.** Only [normaliseOs] is here so far, because `remote_parsers.dart` dispatches on
/// it. The ~940 lines of shell command strings land with the screens that issue them
/// (MIGRATION.md §3.2).
library;

import 'kotlin_strings.dart';

/// Collapses `uname -s` output (or a Windows shell's error text) to one of the four families the
/// metrics parsers branch on.
///
/// An empty or unrecognised result deliberately maps to "Linux": it is the safest superset, and a
/// host that answers something unexpected is far more likely to be an unusual Unix than a Windows
/// box. Windows is detected from its *failure* text, since `uname` does not exist there.
String normaliseOs(String raw) {
  final s = raw.trim().lines.where((l) => !l.isBlankString).firstOrNull?.trim() ?? '';
  final lower = s.toLowerCase();
  if (lower.startsWith('linux')) return 'Linux';
  if (lower.startsWith('freebsd') ||
      lower.startsWith('openbsd') ||
      lower.startsWith('netbsd') ||
      lower.startsWith('dragonfly')) {
    return 'FreeBSD';
  }
  if (lower.startsWith('darwin')) return 'Darwin';
  if (lower.contains('windows') ||
      lower.contains('not recognized') ||
      lower.contains('commandnotfound')) {
    return 'Windows';
  }
  // Empty (missing @OS section) or unknown Unix-like → Linux, the safest superset.
  return 'Linux';
}
