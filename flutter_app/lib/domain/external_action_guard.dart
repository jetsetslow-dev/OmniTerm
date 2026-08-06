import 'package:flutter/foundation.dart';

/// External action payload originating from a home widget, shortcut, or notification.
@immutable
class ExternalAction {
  const ExternalAction({
    required this.id,
    required this.type,
    this.targetId,
    this.uri,
  });

  final String id;
  final String type; // e.g. 'connect_host', 'open_tab'
  final int? targetId;
  final Uri? uri;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ExternalAction &&
          runtimeType == other.runtimeType &&
          id == other.id &&
          type == other.type &&
          targetId == other.targetId &&
          uri == other.uri;

  @override
  int get hashCode => Object.hash(id, type, targetId, uri);
}

/// Pattern O Guard (§20.1/§20.3):
/// Ensures cold-start external actions (widget tap, notification action, app shortcut)
/// MUST await app-lock verification before execution, and are consumed EXACTLY ONCE.
class ExternalActionGuard {
  ExternalAction? _pendingAction;

  ExternalAction? get pendingAction => _pendingAction;

  /// Queue an external action for execution.
  void setPendingAction(ExternalAction action) {
    _pendingAction = action;
  }

  /// Try to consume the pending action.
  /// If [isAppLocked] is true, the action remains queued and returns null.
  /// If [isAppLocked] is false and an action is pending, returns the action and clears the queue
  /// so it is consumed exactly once.
  ExternalAction? tryConsume({required bool isAppLocked}) {
    if (isAppLocked) return null;
    final action = _pendingAction;
    _pendingAction = null;
    return action;
  }

  /// Clear any pending action without executing it.
  void clear() {
    _pendingAction = null;
  }
}
