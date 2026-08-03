import 'dart:typed_data';

/// Events decoded from a tmux control-mode (`tmux -C attach`) stream.
///
/// Ported from the `TmuxControlEvent` hierarchy in `data/term/TmuxControl.kt`.
///
/// Control mode is the transport iTerm2's tmux integration is built on: tmux emits structured
/// line-based events instead of rendering a text UI, and streams **every** byte of pane output as
/// `%output`. That is what makes the "fast output collapses into a repaint and unseen rows are lost"
/// failure of a regular attach impossible by construction.
sealed class TmuxControlEvent {
  const TmuxControlEvent();
}

/// Raw terminal bytes for one pane — feed to that pane's terminal emulator.
class TmuxOutput extends TmuxControlEvent {
  const TmuxOutput(this.paneId, this.data);

  final String paneId;
  final Uint8List data;
}

/// A completed `%begin`…`%end`/`%error` command reply, body newline-joined.
class TmuxReply extends TmuxControlEvent {
  const TmuxReply(this.body, {required this.isError});

  final String body;
  final bool isError;

  @override
  bool operator ==(Object other) =>
      other is TmuxReply && other.body == body && other.isError == isError;

  @override
  int get hashCode => Object.hash(body, isError);

  @override
  String toString() => 'TmuxReply(${isError ? 'error' : 'ok'}, $body)';
}

/// `%session-changed $<id> <name>`.
class TmuxSessionChanged extends TmuxControlEvent {
  const TmuxSessionChanged(this.sessionId, this.name);

  final String sessionId;
  final String name;

  @override
  bool operator ==(Object other) =>
      other is TmuxSessionChanged && other.sessionId == sessionId && other.name == name;

  @override
  int get hashCode => Object.hash(sessionId, name);

  @override
  String toString() => 'TmuxSessionChanged($sessionId, $name)';
}

/// `%exit [reason]` — the control conversation is over (detached, killed, or error).
class TmuxExit extends TmuxControlEvent {
  const TmuxExit(this.reason);

  final String? reason;

  @override
  bool operator ==(Object other) => other is TmuxExit && other.reason == reason;

  @override
  int get hashCode => reason.hashCode;

  @override
  String toString() => 'TmuxExit($reason)';
}

/// Any other `%`-notification (window-add, layout-change, …), passed through verbatim.
class TmuxNotification extends TmuxControlEvent {
  const TmuxNotification(this.line);

  final String line;

  @override
  bool operator ==(Object other) => other is TmuxNotification && other.line == line;

  @override
  int get hashCode => line.hashCode;

  @override
  String toString() => 'TmuxNotification($line)';
}
