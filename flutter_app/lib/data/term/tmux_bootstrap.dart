/// The shell commands that put a session inside tmux, so it survives losing the connection.
///
/// Ported from the `tmux*Command` builders in `data/RemoteParsers.kt`. These are the whole reason a
/// "persistent session" is persistent: the app opens an ordinary SSH shell and immediately
/// `exec`s into a named tmux session, so a dropped link leaves the work running on the server
/// rather than killing it.
///
/// Pure string construction, kept away from the transport so the one genuinely dangerous part —
/// putting a name into a shell command — can be tested exhaustively.
library;

/// Bounds tmux's scrollback. Below this a resumed session has nothing useful to show; above it a
/// long-lived session on a small server is a memory leak with a friendly name.
const tmuxHistoryMin = 1000;
const tmuxHistoryMax = 50000;

/// Reduces [name] to the characters that are safe to paste into a shell command.
///
/// **This is a security boundary, not tidying.** The result is interpolated into a command that the
/// remote runs, so anything surviving here runs there: a session named `x; rm -rf ~` would be two
/// commands rather than one name. Allowing only letters, digits and `-` means there is nothing left
/// to quote or escape — no shell metacharacter, no whitespace, no quote, no newline can reach the
/// remote at all.
///
/// A name that filters down to nothing becomes `omniterm`, because a blank `-t` would attach to
/// whatever session tmux happened to pick.
String tmuxSafeName(String name) {
  final filtered = name.split('').where((c) {
    final code = c.codeUnitAt(0);
    final isDigit = code >= 0x30 && code <= 0x39;
    final isUpper = code >= 0x41 && code <= 0x5A;
    final isLower = code >= 0x61 && code <= 0x7A;
    return isDigit || isUpper || isLower || c == '-';
  }).join();
  return filtered.isEmpty ? 'omniterm' : filtered;
}

int _boundedHistory(int limit) => limit.clamp(tmuxHistoryMin, tmuxHistoryMax);

/// Prepares a session that already exists, before a client attaches to it.
String _existingBootstrap(String safe, int historyLimit) {
  final limit = _boundedHistory(historyLimit);
  return 'command -v tmux >/dev/null 2>&1 && '
      'tmux has-session -t $safe 2>/dev/null && '
      '(tmux set-option -t $safe history-limit $limit >/dev/null 2>&1 || true) && '
      // Touch scrolling is handled by the app against its own buffer. Leaving tmux's mouse mode on
      // would let an ordinary drag land in tmux copy-mode instead, which looks like the terminal
      // freezing.
      '(tmux set-option -t $safe mouse off >/dev/null 2>&1 || true) && ';
}

/// Creates a brand-new session, failing rather than attaching if the name is already taken.
String _createBootstrap(String safe, int historyLimit) {
  final limit = _boundedHistory(historyLimit);
  return 'command -v tmux >/dev/null 2>&1 && '
      // One invocation starts the server, sets the global default and creates the session.
      // `history-limit` applies only to panes created afterwards, so it has to be set before the
      // session exists rather than on it.
      'tmux start-server \\; set-option -g history-limit $limit \\; new-session -d -s $safe && '
      '(tmux set-option -t $safe mouse off >/dev/null 2>&1 || true) && ';
}

/// Creates [name] and attaches to it.
///
/// `exec` on purpose: the tmux client replaces the login shell, so leaving tmux ends the SSH
/// session cleanly instead of dropping the user at a bare prompt they did not ask for.
///
/// Every command is guarded by `command -v tmux`, so a host without tmux is left in a perfectly
/// ordinary shell rather than a half-broken one — the feature degrades to "not persistent", which
/// is the honest outcome.
String tmuxCreateAttachCommand(String name, {int historyLimit = 10000}) {
  final safe = tmuxSafeName(name);
  return '${_createBootstrap(safe, historyLimit)}exec tmux attach-session -t $safe\n';
}

/// Attaches to a session that already exists.
///
/// Fails — leaving an ordinary shell — when the session is gone. Prefer [tmuxResumeCommand] for
/// reconnecting to a remembered name; see the note there.
String tmuxAttachCommand(String name, {int historyLimit = 10000}) {
  final safe = tmuxSafeName(name);
  return '${_existingBootstrap(safe, historyLimit)}exec tmux attach-session -t $safe\n';
}

/// Reconnects to a remembered session, **creating it again if the server no longer has it**.
///
/// This is what a reconnect must use, and the distinction is not academic. A plain attach is a
/// chain of `&&`: when `has-session` fails — the server rebooted, someone ran `tmux kill-server`,
/// the session timed out — every later step is skipped and the user is dropped into a perfectly
/// ordinary shell **that is no longer persistent, with nothing saying so**. Worse, the remembered
/// name never becomes valid again, so every future reconnect degrades the same way. Verified
/// against a real server: the chain exits 1 and leaves a plain prompt.
///
/// `has-session || new-session` rather than tmux's own `new-session -A`: that flag reports failure
/// when the session already exists on the tmux shipped by the lab's image, which would reintroduce
/// exactly the silent degrade this exists to remove.
String tmuxResumeCommand(String name, {int historyLimit = 10000}) {
  final safe = tmuxSafeName(name);
  final limit = _boundedHistory(historyLimit);
  return 'command -v tmux >/dev/null 2>&1 && '
      '{ tmux has-session -t $safe 2>/dev/null || '
      'tmux start-server \\; set-option -g history-limit $limit \\; '
      'new-session -d -s $safe; } && '
      '(tmux set-option -t $safe history-limit $limit >/dev/null 2>&1 || true) && '
      '(tmux set-option -t $safe mouse off >/dev/null 2>&1 || true) && '
      'exec tmux attach-session -t $safe\n';
}

/// Attaches in **control mode** (`tmux -C`).
///
/// tmux then emits structured `%output` events carrying every pane byte instead of drawing a client
/// UI, so output the user has not seen yet cannot be collapsed into a repaint — which is what
/// `tmux_control_parser.dart` consumes. Single `-C`, not `-CC`: the double form wraps the
/// conversation in a DCS envelope meant for terminal-embedded clients.
String tmuxControlAttachCommand(String name, {int historyLimit = 10000}) {
  final safe = tmuxSafeName(name);
  return '${_existingBootstrap(safe, historyLimit)}exec tmux -C attach-session -t $safe\n';
}

/// Creates [name] and attaches to it in control mode.
String tmuxControlCreateAttachCommand(String name, {int historyLimit = 10000}) {
  final safe = tmuxSafeName(name);
  return '${_createBootstrap(safe, historyLimit)}exec tmux -C attach-session -t $safe\n';
}
