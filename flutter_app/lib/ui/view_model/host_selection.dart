import 'package:flutter/foundation.dart';

/// Keys picked on each host: a list's multi-select, or which of its rows are open.
///
/// Kept per host because users switch hosts often and do the same or different work on each. Rows
/// picked on one host must never be acted on while another is shown (a volume called `data` exists
/// on most hosts), and switching back finds the picks as they were left.
class HostSelection {
  HostSelection(this._onChanged);

  final VoidCallback _onChanged;
  final Map<int, Set<String>> _picked = {};
  final Set<int> _selecting = {};

  /// Whether [host]'s list is in multi-select mode.
  bool isSelecting(int? host) => _selecting.contains(host);

  Set<String> picked(int? host) => Set.unmodifiable(_picked[host] ?? const <String>{});

  bool isPicked(int? host, String key) => _picked[host]?.contains(key) ?? false;

  /// Turns multi-select on or off for [host]; turning it off drops that host's picks.
  void toggleSelecting(int? host) {
    if (host == null) return;
    if (_selecting.remove(host)) {
      _picked.remove(host);
    } else {
      _selecting.add(host);
    }
    _onChanged();
  }

  /// Picks [key] on [host], or un-picks it.
  void toggle(int? host, String key) {
    if (host == null) return;
    final keys = _picked.putIfAbsent(host, () => {});
    if (!keys.remove(key)) keys.add(key);
    _onChanged();
  }

  /// Ends [host]'s multi-select and drops its picks, as after acting on them.
  void clear(int? host) {
    if (_selecting.remove(host) | (_picked.remove(host) != null)) _onChanged();
  }
}
