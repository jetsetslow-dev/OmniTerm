import 'dart:typed_data';

/// Commands sent **to** tmux on the control channel (plain text lines).
///
/// Ported from `TmuxControlCommands` in `data/term/TmuxControl.kt`.
///
/// Every function that takes a pane id validates it against `%\d+` before interpolating. These
/// strings become tmux command lines, so an unvalidated id is a command-injection vector — the
/// checks are load-bearing, not defensive noise.
abstract final class TmuxControlCommands {
  static final _paneIdPattern = RegExp(r'^%\d+$');
  static const _hex = '0123456789abcdef';
  static const _paneOutputStates = {'on', 'off', 'pause', 'continue'};

  static void _requirePaneId(String paneId) {
    if (!_paneIdPattern.hasMatch(paneId)) {
      throw ArgumentError('invalid tmux pane id: $paneId');
    }
  }

  /// Keystrokes/paste as hex bytes (`send-keys -H`), chunked so a large paste never exceeds tmux's
  /// command-line limits.
  ///
  /// Bytes are passed through exactly — no shell, no escaping — which is precisely why this is safe
  /// for arbitrary binary input where a quoted string would not be.
  static List<String> sendKeysHex(String paneId, Uint8List data, {int chunkSize = 128}) {
    _requirePaneId(paneId);
    if (chunkSize <= 0) {
      throw ArgumentError('tmux input chunk size must be positive');
    }
    if (data.isEmpty) return const [];

    final commands = <String>[];
    final hex = StringBuffer();
    var inChunk = 0;
    for (final b in data) {
      hex
        ..write(' ')
        ..write(_hex[(b >> 4) & 0xF])
        ..write(_hex[b & 0xF]);
      if (++inChunk == chunkSize) {
        commands.add('send-keys -t $paneId -H$hex');
        hex.clear();
        inChunk = 0;
      }
    }
    if (hex.isNotEmpty) commands.add('send-keys -t $paneId -H$hex');
    return commands;
  }

  /// Tell tmux the control client's pane size (XxY form, verified on tmux 3.3a).
  static String refreshClientSize(int cols, int rows) =>
      'refresh-client -C ${cols < 1 ? 1 : cols}x${rows < 1 ? 1 : rows}';

  /// Pause/resume one pane's control-mode output while taking an atomic screen snapshot.
  static String paneOutputState(String paneId, String state) {
    _requirePaneId(paneId);
    if (!_paneOutputStates.contains(state)) {
      throw ArgumentError('invalid pane output state: $state');
    }
    // In a control-mode command line a colon-qualified pane id must escape its leading '%'. tmux
    // 3.3a accepts a bare `%0` as a target (`send-keys -t %0`) but parses bare `%0:pause` as syntax,
    // returning `parse error: syntax error` and aborting our init.
    return 'refresh-client -A \\$paneId:$state';
  }

  /// Pane history + visible screen come back as a reply body.
  static String capturePane(String paneId, int historyLines, {required bool includeScreen}) {
    _requirePaneId(paneId);
    final tail = includeScreen ? '' : ' -E -1';
    return 'capture-pane -p -e -J -S -${historyLines < 0 ? 0 : historyLines}$tail -t $paneId';
  }

  /// Clear the target pane's history without touching its visible screen.
  static String clearHistory(String paneId) {
    _requirePaneId(paneId);
    return 'clear-history -t $paneId';
  }

  /// Active pane id + cursor for the initial repaint seed (reply body: `%N x y`).
  static String activePaneQuery() =>
      "display-message -p '#{pane_id} #{cursor_x} #{cursor_y}'";
}
