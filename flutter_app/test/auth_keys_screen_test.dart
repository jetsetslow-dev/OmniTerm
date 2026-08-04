import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omniterm/data/app_database.dart';
import 'package:omniterm/data/app_repository.dart';
import 'package:omniterm/data/ssh/ssh_host_key_trust.dart';
import 'package:omniterm/platform/secret_store.dart';
import 'package:omniterm/ui/screens/tools/auth_keys_screen.dart';
import 'package:omniterm/ui/theme/theme.dart';
import 'package:omniterm/ui/view_model/app_state.dart';
import 'package:omniterm/ui/view_model/auth_keys_view_model.dart';
import 'package:provider/provider.dart';

import 'auth_keys_view_model_test.dart' show testPrivateKey, testPublicKey;
import 'support/fake_secure_storage.dart';

void main() {
  late AppDatabase db;
  late AppRepository repo;
  late AppState app;
  late AuthKeysViewModel vm;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    repo = AppRepository(db, SecretStore(storage: FakeSecureStorage(<String, String>{})));
    app = AppState(repo);
  });

  tearDown(() async {
    app.dispose();
    await db.close();
  });

  /// Ends a test cleanly: the credential streams are drift `watch` subscriptions, and cancelling
  /// them is asynchronous — without pumping once, the framework's end-of-test check still sees a
  /// pending timer and fails the test.
  Future<void> finish(WidgetTester tester) async {
    vm.dispose();
    // Two pumps: cancelling a drift `watch` subscription schedules zero-duration timers, and the
    // framework's end-of-test check fails while any remain queued.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 10));
  }

  Server server({required String name, String? keyAlias}) => Server(
        id: 0,
        name: name,
        host: '10.0.0.1',
        port: 22,
        username: 'root',
        serverColor: 'Default',
        authType: keyAlias != null ? 'key' : 'password',
        authKeyAlias: keyAlias,
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
        status: 'offline',
        authStatus: 'unknown',
      );

  Future<void> pump(WidgetTester tester, {SshHostKeyTrust? trust}) async {
    await app.start();
    vm = AuthKeysViewModel(app, hostKeyTrust: trust);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<AppState>.value(value: app),
          ChangeNotifierProvider<AuthKeysViewModel>.value(value: vm),
        ],
        child: MaterialApp(
          theme: omniTheme(OmniThemeMode.dark, Brightness.dark),
          home: const Scaffold(body: AuthKeysScreen()),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('empty sections explain what they are for', (tester) async {
    await pump(tester);

    expect(find.byKey(const ValueKey('authKeys.profiles.empty')), findsOneWidget);
    expect(find.byKey(const ValueKey('authKeys.keys.empty')), findsOneWidget);
    // With no trust store wired, the section says that rather than showing an empty list.
    expect(find.byKey(const ValueKey('authKeys.trust.unavailable')), findsOneWidget);
    await finish(tester);
  });

  group('importing a key', () {
    testWidgets('a valid key is imported and listed', (tester) async {
      await pump(tester);

      await tester.tap(find.byKey(const ValueKey('authKeys.importKey')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('authKeys.import.alias')), 'laptop');
      await tester.enterText(
          find.byKey(const ValueKey('authKeys.import.private')), testPrivateKey);
      await tester.enterText(
          find.byKey(const ValueKey('authKeys.import.public')), testPublicKey);
      await tester.tap(find.byKey(const ValueKey('authKeys.import.save')));
      await tester.pumpAndSettle();

      expect(find.text('laptop'), findsOneWidget);
      expect(find.text('ED25519'), findsOneWidget);
      expect(find.textContaining('SHA256:'), findsWidgets);
      await finish(tester);
    });

    testWidgets('a bad key keeps the sheet open and says why', (tester) async {
      await pump(tester);

      await tester.tap(find.byKey(const ValueKey('authKeys.importKey')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('authKeys.import.alias')), 'oops');
      // Pasting the public key into the private field is the most likely mistake.
      await tester.enterText(
          find.byKey(const ValueKey('authKeys.import.private')), testPublicKey);
      await tester.tap(find.byKey(const ValueKey('authKeys.import.save')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('authKeys.import.error')), findsOneWidget);
      expect(find.textContaining('public key'), findsWidgets);
      expect(find.byKey(const ValueKey('authKeys.import.save')), findsOneWidget,
          reason: 'the sheet stays open so the paste can be corrected');
      await finish(tester);
    });
  });

  group('deleting a key', () {
    testWidgets('the dependent hosts are named in the confirmation', (tester) async {
      // "Delete this key" gives no sense of the blast radius.
      await pump(tester);
      await vm.importKey(alias: 'laptop', privateKey: testPrivateKey);
      await repo.insertServer(server(name: 'web-prod', keyAlias: 'laptop'));
      await tester.pumpAndSettle();

      final key = vm.keys.single;
      await tester.tap(find.byKey(ValueKey('authKeys.key.${key.id}.delete')));
      await tester.pumpAndSettle();

      expect(find.textContaining('web-prod'), findsOneWidget);
      expect(find.textContaining('cannot be recovered'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('authKeys.deleteKey.cancel')));
      await tester.pumpAndSettle();
      expect(vm.keys, hasLength(1));
      await finish(tester);
    });

    testWidgets('confirming removes it', (tester) async {
      await pump(tester);
      await vm.importKey(alias: 'laptop', privateKey: testPrivateKey);
      await tester.pumpAndSettle();

      final key = vm.keys.single;
      await tester.tap(find.byKey(ValueKey('authKeys.key.${key.id}.delete')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('authKeys.deleteKey.confirm')));
      await tester.pumpAndSettle();

      expect(vm.keys, isEmpty);
      await finish(tester);
    });
  });

  group('credential profiles', () {
    testWidgets('a password profile is created', (tester) async {
      await pump(tester);

      await tester.tap(find.byKey(const ValueKey('authKeys.addProfile')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('authKeys.profile.name')), 'shared');
      await tester.enterText(find.byKey(const ValueKey('authKeys.profile.username')), 'deploy');
      await tester.enterText(find.byKey(const ValueKey('authKeys.profile.password')), 'hunter2');
      await tester.tap(find.byKey(const ValueKey('authKeys.profile.save')));
      await tester.pumpAndSettle();

      expect(find.text('shared'), findsOneWidget);
      expect(find.textContaining('User: deploy'), findsOneWidget);
      await finish(tester);
    });

    testWidgets('an incomplete profile is refused inside the sheet', (tester) async {
      await pump(tester);

      await tester.tap(find.byKey(const ValueKey('authKeys.addProfile')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('authKeys.profile.save')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('authKeys.profile.error')), findsOneWidget);
      expect(vm.profiles, isEmpty);
      await finish(tester);
    });

    testWidgets('editing does not show the stored password', (tester) async {
      // Same rule as the host form: a saved secret is never rendered into a field.
      await pump(tester);
      await vm.saveProfile(
        profileName: 'shared',
        username: 'deploy',
        authType: 'password',
        password: 'hunter2',
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(ValueKey('authKeys.profile.${vm.profiles.single.id}.edit')));
      await tester.pumpAndSettle();

      final field = tester.widget<EditableText>(
        find.descendant(
          of: find.byKey(const ValueKey('authKeys.profile.password')),
          matching: find.byType(EditableText),
        ),
      );
      expect(field.controller.text, isEmpty);
      expect(field.obscureText, isTrue);
      expect(find.text('Saved — leave blank to keep'), findsOneWidget);
      await finish(tester);
    });

    testWidgets('deleting names the hosts that lose their credentials', (tester) async {
      await pump(tester);
      await vm.saveProfile(profileName: 'shared', username: 'deploy', authType: 'password');
      await tester.pumpAndSettle();
      final profile = vm.profiles.single;
      await repo.insertServer(
        server(name: 'web-prod').copyWith(authProfileId: Value(profile.id)),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(ValueKey('authKeys.profile.${profile.id}.delete')));
      await tester.pumpAndSettle();
      expect(find.textContaining('web-prod'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('authKeys.deleteProfile.cancel')));
      await tester.pumpAndSettle();
      expect(vm.profiles, hasLength(1));
      await finish(tester);
    });
  });

  group('trusted host keys', () {
    testWidgets('pinned hosts are listed with their fingerprint', (tester) async {
      final store = InMemoryHostKeyStore();
      await store.write(
        '${SshHostKeyTrust.canonicalAlias('10.0.0.9', 2222)}|ssh-ed25519',
        'SHA256:abc',
      );
      await pump(tester, trust: SshHostKeyTrust(store));

      expect(find.byKey(const ValueKey('authKeys.trust.list')), findsOneWidget);
      expect(find.textContaining('SHA256:abc'), findsOneWidget);
      await finish(tester);
    });

    testWidgets('revoking explains what it costs before doing it', (tester) async {
      // Forgetting a pin removes the protection that would catch an interception.
      final store = InMemoryHostKeyStore();
      await store.write(
        '${SshHostKeyTrust.canonicalAlias('10.0.0.9', 2222)}|ssh-ed25519',
        'SHA256:abc',
      );
      await pump(tester, trust: SshHostKeyTrust(store));

      final host = vm.knownHosts.single;
      await tester.tap(find.byKey(ValueKey('authKeys.trust.${host.host}.revoke')));
      await tester.pumpAndSettle();

      expect(find.textContaining('present its key for approval again'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('authKeys.revoke.cancel')));
      await tester.pumpAndSettle();
      expect(await store.readAll(), isNotEmpty, reason: 'cancelling must keep the pin');

      await tester.tap(find.byKey(ValueKey('authKeys.trust.${host.host}.revoke')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('authKeys.revoke.confirm')));
      await tester.pumpAndSettle();

      expect(await store.readAll(), isEmpty);
      expect(vm.knownHosts, isEmpty);
      await finish(tester);
    });

    testWidgets('without a trust store the section says so', (tester) async {
      await pump(tester);
      expect(find.byKey(const ValueKey('authKeys.trust.unavailable')), findsOneWidget);
      await finish(tester);
    });
  });
}
