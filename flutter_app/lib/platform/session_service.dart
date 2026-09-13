import 'dart:async';

import 'package:flutter/services.dart';

/// One background session, as the notification shade shows it.
class BackgroundSession {
  const BackgroundSession({required this.id, required this.serverName});

  final String id;
  final String serverName;

  Map<String, Object?> toArguments() => {'id': id, 'serverName': serverName};

  @override
  bool operator ==(Object other) =>
      other is BackgroundSession && other.id == id && other.serverName == serverName;

  @override
  int get hashCode => Object.hash(id, serverName);

  @override
  String toString() => 'BackgroundSession($id, $serverName)';
}

/// Something the user did from the notification shade.
sealed class SessionServiceAction {
  const SessionServiceAction();

  /// Parses a message from the platform, or null when it is not one we understand.
  static SessionServiceAction? parse(Object? event) {
    if (event is! Map) return null;
    final id = event['session'] as String?;
    return switch (event['action']) {
      'disconnect' when id != null => DisconnectSession(id),
      'disconnectAll' => const DisconnectAllSessions(),
      'resume' when id != null => ResumeSession(id),
      _ => null,
    };
  }
}

class DisconnectSession extends SessionServiceAction {
  const DisconnectSession(this.sessionId);
  final String sessionId;

  @override
  bool operator ==(Object other) => other is DisconnectSession && other.sessionId == sessionId;

  @override
  int get hashCode => sessionId.hashCode;
}

class DisconnectAllSessions extends SessionServiceAction {
  const DisconnectAllSessions();

  @override
  bool operator ==(Object other) => other is DisconnectAllSessions;

  @override
  int get hashCode => 0;
}

class ResumeSession extends SessionServiceAction {
  const ResumeSession(this.sessionId);
  final String sessionId;

  @override
  bool operator ==(Object other) => other is ResumeSession && other.sessionId == sessionId;

  @override
  int get hashCode => sessionId.hashCode;
}

/// Keeps SSH sessions alive while the app is in the background.
///
/// Android stops scheduling a backgrounded process within moments, which for a terminal app means
/// every open shell dies the instant the user checks a message. A foreground service is the only
/// sanctioned way to say "this process is doing something the user asked for" — and the visible
/// notification is the *point*, not a tax: a process holding SSH connections open should be
/// something the user can see and stop.
///
/// iOS has no equivalent and is not expected to: the platform genuinely does not allow it, so
/// [isSupported] reports false there rather than pretending (Convention 4).
class SessionService {
  SessionService({MethodChannel? channel, EventChannel? actions})
    : _channel = channel ?? const MethodChannel(methodChannelName),
      _actions = actions ?? const EventChannel(eventChannelName);

  static const methodChannelName = 'omniterm/session_service';
  static const eventChannelName = 'omniterm/session_service/actions';

  final MethodChannel _channel;
  final EventChannel _actions;

  Future<bool> isSupported() async {
    try {
      return await _channel.invokeMethod<bool>('isSupported') ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  /// What the user tapped in the shade.
  Stream<SessionServiceAction> get actions => _actions
      .receiveBroadcastStream()
      .map(SessionServiceAction.parse)
      .where((action) => action != null)
      .cast<SessionServiceAction>();

  /// Start or update the service to reflect [sessions].
  ///
  /// One call for both, because "start" and "update" differ only in whether the service was already
  /// running — and a caller that has to know which would get it wrong after a process restart.
  /// An empty list stops the service: a foreground notification with nothing behind it is a lie.
  Future<SessionServiceResult> sync(List<BackgroundSession> sessions) async {
    if (sessions.isEmpty) return stop();
    return _invoke('sync', {'sessions': sessions.map((s) => s.toArguments()).toList()});
  }

  Future<SessionServiceResult> stop() => _invoke('stop');

  Future<SessionServiceResult> _invoke(
    String method, [
    Map<String, Object?> arguments = const {},
  ]) async {
    try {
      final applied = await _channel.invokeMethod<bool>(method, arguments);
      if (applied == true) return const SessionServiceResult.ok();
      // The platform answered, and said no. That is a refusal, not an absence.
      return const SessionServiceResult.failed('the device did not start the background service');
    } on MissingPluginException {
      // No implementation registered at all: iOS, or a build without the bridge. Nothing is wrong
      // and there is nothing the user could do, so this must not read as a failure.
      return const SessionServiceResult.unsupported();
    } on PlatformException catch (e) {
      // Android 12+ throws ForegroundServiceStartNotAllowedException when a start is attempted from
      // the background. That is a real, reportable refusal on a platform that does support this.
      return SessionServiceResult.failed(e.message ?? e.code);
    } catch (e) {
      return SessionServiceResult.failed(e.toString());
    }
  }
}

/// Whether a [SessionService] call actually took effect.
///
/// `bool` could not answer the question that matters. It collapsed "this platform has no
/// foreground service" together with "Android refused to start it", so a keep-alive that failed on
/// a device which *does* support it was indistinguishable from iOS behaving exactly as designed —
/// and the caller, having no way to tell them apart, reported neither. The user kept believing
/// their shells were protected in the background while they were not.
enum SessionServiceOutcome { ok, unsupported, failed }

class SessionServiceResult {
  const SessionServiceResult.ok() : outcome = SessionServiceOutcome.ok, detail = null;
  const SessionServiceResult.unsupported()
    : outcome = SessionServiceOutcome.unsupported,
      detail = null;
  const SessionServiceResult.failed(this.detail) : outcome = SessionServiceOutcome.failed;

  final SessionServiceOutcome outcome;

  /// Why it failed, as the platform described it. Null unless [outcome] is
  /// [SessionServiceOutcome.failed].
  final String? detail;

  bool get ok => outcome == SessionServiceOutcome.ok;
  bool get failed => outcome == SessionServiceOutcome.failed;

  @override
  String toString() => 'SessionServiceResult(${outcome.name}${detail == null ? '' : ', $detail'})';
}
