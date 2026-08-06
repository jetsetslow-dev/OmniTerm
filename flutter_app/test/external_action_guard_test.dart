import 'package:flutter_test/flutter_test.dart';
import 'package:omniterm/domain/external_action_guard.dart';

void main() {
  group('ExternalActionGuard (§20.1 Pattern O)', () {
    test('action remains pending while app is locked', () {
      final guard = ExternalActionGuard();
      const action = ExternalAction(
        id: 'action-1',
        type: 'connect_host',
        targetId: 42,
      );

      guard.setPendingAction(action);
      expect(guard.pendingAction, equals(action));

      // Attempt to consume while locked
      final resultWhileLocked = guard.tryConsume(isAppLocked: true);
      expect(resultWhileLocked, isNull);
      expect(guard.pendingAction, equals(action));
    });

    test('action is consumed exactly once when app is unlocked', () {
      final guard = ExternalActionGuard();
      const action = ExternalAction(
        id: 'action-1',
        type: 'connect_host',
        targetId: 42,
      );

      guard.setPendingAction(action);

      // Consume when unlocked
      final consumed = guard.tryConsume(isAppLocked: false);
      expect(consumed, equals(action));
      expect(guard.pendingAction, isNull);

      // Second attempt returns null (consumed at most once)
      final secondAttempt = guard.tryConsume(isAppLocked: false);
      expect(secondAttempt, isNull);
    });

    test('clear removes pending action without executing', () {
      final guard = ExternalActionGuard();
      const action = ExternalAction(
        id: 'action-1',
        type: 'connect_host',
        targetId: 42,
      );

      guard.setPendingAction(action);
      guard.clear();
      expect(guard.pendingAction, isNull);
      expect(guard.tryConsume(isAppLocked: false), isNull);
    });
  });
}
