import 'dart:async';

import 'package:omniterm/platform/session_service.dart';

/// Records what the platform was asked to show, and lets a test push shade actions back.
class FakeSessionService implements SessionService {
  final List<List<BackgroundSession>> synced = [];
  int stops = 0;
  final _actions = StreamController<SessionServiceAction>.broadcast();

  @override
  Stream<SessionServiceAction> get actions => _actions.stream;

  @override
  Future<bool> isSupported() async => true;

  /// What the platform answers. Defaults to success; a test sets it to stage a refusal or an
  /// unsupported platform.
  SessionServiceResult result = const SessionServiceResult.ok();

  @override
  Future<SessionServiceResult> sync(List<BackgroundSession> sessions) async {
    if (sessions.isEmpty) {
      stops++;
    } else {
      synced.add(List.of(sessions));
    }
    return result;
  }

  @override
  Future<SessionServiceResult> stop() async {
    stops++;
    return result;
  }

  void push(SessionServiceAction action) => _actions.add(action);

  Future<void> dispose() => _actions.close();

  @override
  noSuchMethod(Invocation invocation) => throw UnimplementedError();
}
