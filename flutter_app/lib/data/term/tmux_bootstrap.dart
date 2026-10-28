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

import 'package:collection/collection.dart' show mergeSort;

/// Bounds tmux's scrollback. Below this a resumed session has nothing useful to show; above it a
/// long-lived session on a small server is a memory leak with a friendly name.
const tmuxHistoryMin = 1000;
const tmuxHistoryMax = 50000;

/// A letter or digit in any script, `-` or `_`: Kotlin's `isTmuxNameChar`. Tested one UTF-16 unit at
/// a time, as Kotlin's `Char` is, so half of a surrogate pair never qualifies.
final _tmuxNameChar = RegExp(r'^[\p{L}\p{Nd}_-]$', unicode: true);

bool _isTmuxNameChar(int codeUnit) => _tmuxNameChar.hasMatch(String.fromCharCode(codeUnit));

/// Reduces [name] to the characters that are safe to paste into a shell command.
///
/// **This is a security boundary, not tidying.** The result is interpolated into a command that the
/// remote runs, so anything surviving here runs there: a session named `x; rm -rf ~` would be two
/// commands rather than one name. Allowing only letters, digits, `-` and `_` means there is nothing
/// left to quote or escape — no shell metacharacter, no whitespace, no quote, no newline can reach
/// the remote at all. Letters outside ASCII are kept, as Kotlin keeps them: their UTF-8 bytes are
/// never ASCII, so none of them can be read as shell syntax.
///
/// A name that filters down to nothing becomes `omniterm`, because a blank `-t` would attach to
/// whatever session tmux happened to pick.
String tmuxSafeName(String name) {
  final filtered = String.fromCharCodes(name.codeUnits.where(_isTmuxNameChar));
  return filtered.isEmpty ? 'omniterm' : filtered;
}

/// Whether a session found on the host can be attached by its own name: it must pass [tmuxSafeName]
/// unchanged, and must not start with `-`, which tmux would read as an option. tmux's default names
/// (0, 1, …) qualify. Kotlin's `isAttachableTmuxName`.
bool isAttachableTmuxName(String name) =>
    name.isNotEmpty && !name.startsWith('-') && name.codeUnits.every(_isTmuxNameChar);

/// Succeeds only when a session is called exactly [safe]. `-t name` also accepts a session whose
/// name merely starts with it, so once a session called "0" has ended, `has-session -t 0` finds
/// "01", and an attach or kill would act on a session the user never picked.
String _exactSession(String safe) =>
    "tmux list-sessions -F '#{session_name}' 2>/dev/null | grep -qxF -- $safe";

/// The active pane of session [safe]. A bare name is tried as a pane and then a window before a
/// session, so a session called "0" would reach pane 0 of whichever session tmux took as current.
String tmuxPane(String safe) => '$safe:';

int _boundedHistory(int limit) => limit.clamp(tmuxHistoryMin, tmuxHistoryMax);

/// Starts every tmux command: finds a tmux that a package manager put outside the system PATH.
///
/// Kotlin's `RemoteCommands.TMUX_PATH`. A command sent without a terminal starts a non-login shell,
/// and on macOS that shell's PATH is only /usr/bin:/bin:/usr/sbin:/sbin; Homebrew's directory is
/// added by ~/.zprofile, which only login shells read. So on a Mac with Homebrew's tmux the check
/// said tmux was missing, and session checks and End session failed quietly. Covers Homebrew on
/// Apple silicon and Intel, MacPorts, and Homebrew on Linux, and leaves PATH alone wherever tmux is
/// already found.
const tmuxPath =
    'command -v tmux >/dev/null 2>&1 || '
    'PATH="\$PATH:/opt/homebrew/bin:/usr/local/bin:/opt/local/bin:/home/linuxbrew/.linuxbrew/bin"; ';

/// Prepares a session that already exists, before a client attaches to it. A session the user
/// attached from the host's own list is left as it is ([configure] false): their other tmux clients
/// share its options.
String _existingBootstrap(String safe, int historyLimit, {bool configure = true}) {
  final limit = _boundedHistory(historyLimit);
  final bootstrap = '${tmuxPath}command -v tmux >/dev/null 2>&1 && ${_exactSession(safe)} && ';
  if (!configure) return bootstrap;
  return '$bootstrap'
      '(tmux set-option -t $safe history-limit $limit >/dev/null 2>&1 || true) && '
      // Touch scrolling is handled by the app against its own buffer. Leaving tmux's mouse mode on
      // would let an ordinary drag land in tmux copy-mode instead, which looks like the terminal
      // freezing.
      '(tmux set-option -t $safe mouse off >/dev/null 2>&1 || true) && ';
}

/// Creates a brand-new session, failing rather than attaching if the name is already taken.
String _createBootstrap(String safe, int historyLimit) {
  final limit = _boundedHistory(historyLimit);
  return '${tmuxPath}command -v tmux >/dev/null 2>&1 && '
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

/// Attaches to a session that already exists, leaving its options alone when [adopted].
///
/// Fails — leaving an ordinary shell — when the session is gone. Prefer [tmuxResumeCommand] for
/// reconnecting to a remembered name; see the note there.
String tmuxAttachCommand(String name, {int historyLimit = 10000, bool adopted = false}) {
  final safe = tmuxSafeName(name);
  return '${_existingBootstrap(safe, historyLimit, configure: !adopted)}'
      'exec tmux attach-session -t $safe\n';
}

/// Reconnects to a remembered session after [tmuxSessionProbeCommand] confirmed it exists.
///
/// It deliberately never creates a replacement. A server reboot can remove the old shell and all
/// of its work; silently making a new empty session under the same name would claim that recovery
/// succeeded. The caller keeps an unverifiable recovery row, or removes a confirmed-missing row
/// with an explicit warning, before this command is ever sent.
String tmuxResumeCommand(
  String name, {
  int historyLimit = 10000,
  bool controlMode = false,
  bool adopted = false,
}) {
  return controlMode
      ? tmuxControlAttachCommand(name, historyLimit: historyLimit, adopted: adopted)
      : tmuxAttachCommand(name, historyLimit: historyLimit, adopted: adopted);
}

const tmuxSessionPresentMarker = 'OMNITERM_TMUX_PRESENT';
const tmuxSessionAbsentMarker = 'OMNITERM_TMUX_ABSENT';

/// What [tmuxSessionProbeCommand] prints when it cannot tell, and the one marker only it prints.
const tmuxSessionUnknownMarker = 'OMNITERM_TMUX_UNKNOWN';

/// Checks one exact remembered name. A host where tmux cannot be found stays unknown rather than
/// absent, so its saved session is not forgotten while tmux is merely off the PATH.
String tmuxSessionProbeCommand(String name) {
  final safe = tmuxSafeName(name);
  return '${tmuxPath}if ! command -v tmux >/dev/null 2>&1; then echo $tmuxSessionUnknownMarker; '
      'elif ${_exactSession(safe)}; then echo $tmuxSessionPresentMarker; '
      'else echo $tmuxSessionAbsentMarker; fi';
}

bool? parseTmuxSessionProbe(String raw) {
  final response = raw.trim();
  if (response.startsWith('SSH Error:')) return null;
  if (response == tmuxSessionPresentMarker) return true;
  if (response == tmuxSessionAbsentMarker) return false;
  return null;
}

/// Attaches in **control mode** (`tmux -C`).
///
/// tmux then emits structured `%output` events carrying every pane byte instead of drawing a client
/// UI, so output the user has not seen yet cannot be collapsed into a repaint — which is what
/// `tmux_control_parser.dart` consumes. Single `-C`, not `-CC`: the double form wraps the
/// conversation in a DCS envelope meant for terminal-embedded clients.
String tmuxControlAttachCommand(String name, {int historyLimit = 10000, bool adopted = false}) {
  final safe = tmuxSafeName(name);
  return '${_existingBootstrap(safe, historyLimit, configure: !adopted)}'
      'exec tmux -C attach-session -t $safe\n';
}

/// Creates [name] and attaches to it in control mode.
String tmuxControlCreateAttachCommand(String name, {int historyLimit = 10000}) {
  final safe = tmuxSafeName(name);
  return '${_createBootstrap(safe, historyLimit)}exec tmux -C attach-session -t $safe\n';
}

/// Stops one persistent session from a separate SSH exec channel.
String tmuxKillCommand(String name) {
  final safe = tmuxSafeName(name);
  return '$tmuxPath${_exactSession(safe)} && tmux kill-session -t $safe 2>/dev/null';
}

/// Marks a host without tmux in [tmuxListSessionsCommand]'s output.
const tmuxMissingMarker = '##OMNI-NO-TMUX';

/// The host's tmux sessions, one per line: when each was created (epoch seconds), how many clients
/// are attached, how many windows it has, and its name last, since a name the user chose may contain
/// spaces. See [parseTmuxSessions].
const tmuxListSessionsCommand =
    '${tmuxPath}if command -v tmux >/dev/null 2>&1; then '
    "tmux list-sessions -F '#{session_created} #{session_attached} #{session_windows} "
    "#{session_name}' 2>/dev/null; true; "
    "else echo '$tmuxMissingMarker'; fi";

/// A tmux session running on a host, as [parseTmuxSessions] read it.
class RemoteTmuxSession {
  const RemoteTmuxSession({
    required this.name,
    required this.windows,
    required this.attachedClients,
    required this.createdAtMs,
  });

  final String name;
  final int windows;

  /// How many tmux clients are attached to it right now, anywhere.
  final int attachedClients;
  final int createdAtMs;
}

/// The sessions [tmuxListSessionsCommand] listed, oldest first, or null when the host has no tmux.
/// No running tmux server is simply no sessions.
List<RemoteTmuxSession>? parseTmuxSessions(String output) {
  if (output.contains(tmuxMissingMarker)) return null;
  final sessions = <RemoteTmuxSession>[];
  // Every line ending Kotlin's `lineSequence` splits on.
  for (final line in output.split(RegExp(r'\r\n|\n|\r'))) {
    final fields = line.split(' ');
    final created = int.tryParse(fields[0]);
    if (created == null || fields.length < 4) continue;
    final name = fields.sublist(3).join(' ');
    if (name.isEmpty) continue;
    sessions.add(
      RemoteTmuxSession(
        name: name,
        windows: int.tryParse(fields[2]) ?? 0,
        attachedClients: int.tryParse(fields[1]) ?? 0,
        createdAtMs: created * 1000,
      ),
    );
  }
  // Stable, as Kotlin's `sortedBy`.
  mergeSort(sessions, compare: (a, b) => a.createdAtMs.compareTo(b.createdAtMs));
  return sessions;
}
