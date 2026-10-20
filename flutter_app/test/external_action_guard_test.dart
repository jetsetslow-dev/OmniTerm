import 'package:drift/native.dart';
import 'package:omniterm/data/app_database.dart';
import 'package:omniterm/data/app_repository.dart';
import 'package:omniterm/platform/secret_store.dart';
import 'package:omniterm/ui/view_model/app_state.dart';

import 'support/fake_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omniterm/domain/external_action_guard.dart';

void main() {
  group('ExternalActionGuard (§20.1 Pattern O)', () {
    test('action remains pending while app is locked', () {
      final guard = ExternalActionGuard();
      const action = ExternalAction(id: 'action-1', type: 'connect_host', targetId: 42);

      guard.setPendingAction(action);
      expect(guard.pendingAction, equals(action));

      // Attempt to consume while locked
      final resultWhileLocked = guard.tryConsume(isAppLocked: true);
      expect(resultWhileLocked, isNull);
      expect(guard.pendingAction, equals(action));
    });

    test('action is consumed exactly once when app is unlocked', () {
      final guard = ExternalActionGuard();
      const action = ExternalAction(id: 'action-1', type: 'connect_host', targetId: 42);

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
      const action = ExternalAction(id: 'action-1', type: 'connect_host', targetId: 42);

      guard.setPendingAction(action);
      guard.clear();
      expect(guard.pendingAction, isNull);
      expect(guard.tryConsume(isAppLocked: false), isNull);
    });
  });

  group('resolving a shortcut target on a cold start', () {
    // The premise of the fix in `_executeExternalAction`: a launcher shortcut can arrive before the
    // host stream has emitted, so the in-memory list is empty and a perfectly good shortcut looked
    // like a deleted host. Kotlin reads the row directly for the same reason
    // (`ui/AppViewModel.kt:4533`).
    test('the repository answers before the host stream has', () async {
      final db = AppDatabase(NativeDatabase.memory());
      final repo = AppRepository(db, SecretStore(storage: FakeSecureStorage(<String, String>{})));
      final id = await repo.insertServer(_shortcutHost());
      final app = AppState(repo);

      // Deliberately not awaiting `start()`: this is the cold-start moment the defect lived in.
      expect(app.servers, isEmpty, reason: 'the stream has not emitted yet');
      expect(
        await repo.getServerById(id),
        isNotNull,
        reason: 'the row is there regardless, which is why the lookup uses it',
      );

      app.dispose();
      await db.close();
    });
  });
}

Server _shortcutHost() => const Server(
  id: 0,
  name: 'nas',
  host: '10.0.0.1',
  port: 22,
  username: 'root',
  serverColor: 'Default',
  authType: 'password',
  authPassword: 'pw',
  sudoPassword: '',
  notes: '',
  keepAlive: 30,
  sshCompression: false,
  persistentSession: false,
  proxyCommand: '',
  proxyType: 'none',
  proxyHost: '',
  proxyPort: 0,
  proxyUser: '',
  proxyPassword: '',
  agentForwarding: false,
  healthScore: 100,
  lastLatency: 0,
  status: 'online',
  authStatus: 'ok',
);
