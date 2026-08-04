/// POSIX remote-path helpers, extracted from the path handling scattered through
/// `ui/SftpScreen.kt` and `AppViewModel.kt`.
///
/// These are always **remote** paths, so `dart:io`'s `path` package is deliberately not used: it
/// follows the *host* platform's separator, and on Windows it would build `C:\srv\www` for a Linux
/// server. POSIX rules are hard-coded because the far side is always POSIX.
library;

/// The parent of [path], or "/" at the root.
///
/// Returns "/" rather than "" for a top-level entry, so "up" from `/etc` lands somewhere navigable
/// instead of at an empty path the server would reject.
String parentPath(String path) {
  final normalised = normalisePath(path);
  if (normalised == '/') return '/';
  final index = normalised.lastIndexOf('/');
  if (index <= 0) return '/';
  return normalised.substring(0, index);
}

/// Joins [name] onto [base] without doubling or dropping the separator.
String joinPath(String base, String name) {
  if (base.isEmpty || base == '/') return '/$name';
  final trimmed = base.endsWith('/') ? base.substring(0, base.length - 1) : base;
  return '$trimmed/$name';
}

/// The last component of [path] — the file or directory name.
String baseName(String path) {
  final normalised = normalisePath(path);
  if (normalised == '/') return '/';
  return normalised.substring(normalised.lastIndexOf('/') + 1);
}

/// Collapses duplicate separators and strips a trailing one.
///
/// `//srv//www/` and `/srv/www` name the same directory, and a UI that treats them as different
/// breaks breadcrumb highlighting and makes "already here" checks fail.
String normalisePath(String path) {
  if (path.isEmpty) return '/';
  final collapsed = path.replaceAll(RegExp('/+'), '/');
  if (collapsed == '/') return '/';
  return collapsed.endsWith('/') ? collapsed.substring(0, collapsed.length - 1) : collapsed;
}

/// The breadcrumb trail for [path]: root first, then each ancestor, ending at [path] itself.
List<({String name, String path})> breadcrumbs(String path) {
  final normalised = normalisePath(path);
  final crumbs = <({String name, String path})>[(name: '/', path: '/')];
  if (normalised == '/') return crumbs;

  var current = '';
  for (final segment in normalised.split('/').where((s) => s.isNotEmpty)) {
    current = '$current/$segment';
    crumbs.add((name: segment, path: current));
  }
  return crumbs;
}

/// True when [child] is [ancestor] or lives beneath it.
///
/// Compared segment-wise, not as a string prefix: `/srv/www-old`.startsWith(`/srv/www`) is true but
/// it is a *sibling*. Used to stop a move that would drag a directory into itself, which on a real
/// filesystem either errors or destroys the subtree.
bool isWithin(String ancestor, String child) {
  final a = normalisePath(ancestor);
  final c = normalisePath(child);
  if (a == '/') return true;
  if (a == c) return true;
  return c.startsWith('$a/');
}

/// A name that is safe to use as a single path component, or null when it is not usable.
///
/// Rejects "" , "." and ".." and anything containing a separator: each would either fail on the
/// server or silently act somewhere other than where the user is looking.
String? validateFileName(String name) {
  final trimmed = name.trim();
  if (trimmed.isEmpty) return null;
  if (trimmed == '.' || trimmed == '..') return null;
  if (trimmed.contains('/')) return null;
  return trimmed;
}

/// A non-clashing name for [name] within [existing], e.g. `notes.txt` → `notes (2).txt`.
///
/// The counter goes before the extension so the file keeps opening in the same application.
String uniqueName(String name, Set<String> existing) {
  if (!existing.contains(name)) return name;

  // A leading dot is the whole name of a dotfile, not an extension: `.bashrc` must become
  // `.bashrc (2)`, never ` (2).bashrc`.
  final dot = name.lastIndexOf('.');
  final hasExtension = dot > 0;
  final stem = hasExtension ? name.substring(0, dot) : name;
  final extension = hasExtension ? name.substring(dot) : '';

  for (var counter = 2; counter < 1000; counter++) {
    final candidate = '$stem ($counter)$extension';
    if (!existing.contains(candidate)) return candidate;
  }
  return '$stem (${DateTime.now().millisecondsSinceEpoch})$extension';
}
