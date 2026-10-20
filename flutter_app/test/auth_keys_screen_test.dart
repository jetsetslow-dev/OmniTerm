import 'dart:async';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omniterm/data/app_database.dart';
import 'package:omniterm/data/app_repository.dart';
import 'package:omniterm/data/ssh/ssh_host_key_trust.dart';
import 'package:omniterm/domain/host_display.dart';
import 'package:omniterm/domain/ssh_keygen.dart';
import 'package:omniterm/platform/secret_store.dart';
import 'package:omniterm/ui/screens/tools/auth_keys_screen.dart';
import 'package:omniterm/ui/theme/theme.dart';
import 'package:omniterm/ui/view_model/app_state.dart';
import 'package:omniterm/ui/view_model/auth_keys_view_model.dart';
import 'package:provider/provider.dart';

import 'support/ed25519_fixture.dart';
import 'support/fake_secure_storage.dart';

void main() {
  late AppDatabase db;
  late AppRepository repo;
  late AppState app;
  late AuthKeysViewModel vm;
  // Generated rather than committed: see test/support/ed25519_fixture.dart.
  late Ed25519Fixture keys;

  setUpAll(() async => keys = await sharedEd25519Fixture());

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

  Future<void> pump(
    WidgetTester tester, {
    SshHostKeyTrust? trust,
    SshKeyGenerator? keyGenerator,
  }) async {
    await app.start();
    vm = AuthKeysViewModel(app, hostKeyTrust: trust, keyGenerator: keyGenerator);
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

  Future<void> choose(WidgetTester tester, String source) async {
    await tester.tap(find.byKey(const ValueKey('authKeys.add')));
    await tester.pumpAndSettle();
    expect(find.text('Add Authentication Source'), findsOneWidget);
    await tester.tap(find.byKey(ValueKey('authKeys.source.$source')));
    await tester.pumpAndSettle();
  }

  Future<void> tapVisible(WidgetTester tester, Finder finder) async {
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  testWidgets('sections carry Kotlin\'s titles and empty trust note', (tester) async {
    await pump(tester);

    expect(find.text('Auth Keys & Profiles'), findsOneWidget);
    expect(find.text('Credential Profiles (Username/Password)'), findsOneWidget);
    expect(find.text('SSH Keys'), findsOneWidget);
    expect(find.text('No trusted host keys yet.'), findsOneWidget);
    await finish(tester);
  });

  testWidgets('+ offers the three Kotlin sources', (tester) async {
    await pump(tester);
    await tester.tap(find.byKey(const ValueKey('authKeys.add')));
    await tester.pumpAndSettle();
    expect(find.text('Profile (User/Pass)'), findsOneWidget);
    expect(find.text('Generate SSH Key'), findsOneWidget);
    expect(find.text('Import SSH Key'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('authKeys.source.cancel')));
    await tester.pumpAndSettle();
    expect(find.text('Add Authentication Source'), findsNothing);
    await finish(tester);
  });

  testWidgets('profile save has progress and prevents duplicate submissions until it finishes', (
    tester,
  ) async {
    app.dispose();
    final delayed = _DelayedProfileRepository(db, SecretStore(storage: FakeSecureStorage({})));
    repo = delayed;
    app = AppState(repo);
    await pump(tester);
    addTearDown(() {
      if (!delayed.release.isCompleted) delayed.release.complete();
    });
    await choose(tester, 'profile');
    await tester.enterText(find.byKey(const ValueKey('authKeys.profile.name')), 'Fixture profile');
    await tester.enterText(find.byKey(const ValueKey('authKeys.profile.username')), 'deploy');
    await tester.enterText(find.byKey(const ValueKey('authKeys.profile.password')), 'hunter2');
    await tester.pump();
    final save = find.byKey(const ValueKey('authKeys.profile.save'));
    await tester.ensureVisible(save);
    await tester.tap(save);
    await tester.pump();
    expect(find.text('Saving…'), findsOneWidget);
    expect(tester.widget<FilledButton>(save).onPressed, isNull);
    expect(
      tester.widget<TextButton>(find.byKey(const ValueKey('authKeys.profile.cancel'))).onPressed,
      isNull,
    );
    expect(delayed.calls, 1);
    delayed.release.complete();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('authKeys.profile.save')), findsNothing);
    expect((await repo.getAllProfiles()).single.profileName, 'Fixture profile');
    expect(find.text("Saved profile 'Fixture profile'."), findsOneWidget);
    await finish(tester);
  });

  testWidgets('conflicting profile edit keeps a scrollable editor open with both server names', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 500);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final id = await repo.insertProfile(
      const CredentialProfile(
        id: 0,
        profileName: 'Shared',
        username: 'deploy',
        authType: 'password',
        groupName: 'General',
      ),
    );
    final original = (await repo.getCredentialProfileById(id))!;
    await repo.insertServer(server(name: 'Existing root'));
    await repo.insertServer(
      server(name: 'Profile deploy').copyWith(authType: 'profile', authProfileId: Value(id)),
    );
    await pump(tester);
    await tester.tap(find.byKey(ValueKey('authKeys.profile.$id.edit')));
    await tester.pumpAndSettle();
    expect(find.text('Edit Credential Profile'), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('authKeys.profile.username')), 'root');
    final save = find.byKey(const ValueKey('authKeys.profile.save'));
    await tapVisible(tester, save);
    final error = find.byKey(const ValueKey('authKeys.profile.error'));
    await tester.ensureVisible(error);
    expect(tester.widget<Text>(error).data, contains('Existing root'));
    expect(tester.widget<Text>(error).data, contains('Profile deploy'));
    expect(await repo.getCredentialProfileById(id), original);
    expect(tester.widget<FilledButton>(save).onPressed, isNotNull);
    await finish(tester);
  });

  group('importing a key', () {
    testWidgets('a valid key is imported and listed in Kotlin form', (tester) async {
      await pump(tester);

      await choose(tester, 'import');
      expect(find.text('Import existing SSH Key'), findsOneWidget);
      await tester.enterText(find.byKey(const ValueKey('authKeys.import.alias')), 'laptop');
      await tester.enterText(
        find.byKey(const ValueKey('authKeys.import.private')),
        keys.privateKey,
      );
      await tester.enterText(find.byKey(const ValueKey('authKeys.import.public')), keys.publicKey);
      await tapVisible(tester, find.byKey(const ValueKey('authKeys.import.save')));

      expect(find.text('laptop'), findsOneWidget);
      expect(find.textContaining('Crypto: ED25519 · Fingerprint: SHA256:'), findsOneWidget);
      expect(find.text("Imported ED25519 key 'laptop'."), findsOneWidget);
      await finish(tester);
    });

    testWidgets('Save Key waits for an alias and a private key', (tester) async {
      await pump(tester);
      await choose(tester, 'import');
      final save = find.byKey(const ValueKey('authKeys.import.save'));
      expect(tester.widget<FilledButton>(save).onPressed, isNull);
      await tester.enterText(find.byKey(const ValueKey('authKeys.import.alias')), 'laptop');
      await tester.pump();
      expect(tester.widget<FilledButton>(save).onPressed, isNull);
      await finish(tester);
    });

    testWidgets('a bad key keeps the dialog open and says why', (tester) async {
      await pump(tester);

      await choose(tester, 'import');
      await tester.enterText(find.byKey(const ValueKey('authKeys.import.alias')), 'oops');
      // Pasting the public key into the private field is the most likely mistake.
      await tester.enterText(find.byKey(const ValueKey('authKeys.import.private')), keys.publicKey);
      await tapVisible(tester, find.byKey(const ValueKey('authKeys.import.save')));

      expect(find.byKey(const ValueKey('authKeys.import.error')), findsOneWidget);
      expect(find.textContaining('public key'), findsWidgets);
      expect(
        find.byKey(const ValueKey('authKeys.import.save')),
        findsOneWidget,
        reason: 'the dialog stays open so the paste can be corrected',
      );
      await finish(tester);
    });
  });

  group('editing a key', () {
    testWidgets('renaming cascades to hosts and key profiles', (tester) async {
      await pump(tester);
      await vm.importKey(alias: 'laptop', privateKey: keys.privateKey);
      await repo.insertServer(server(name: 'web-prod', keyAlias: 'laptop'));
      await repo.insertProfile(
        const CredentialProfile(
          id: 0,
          profileName: 'keyed',
          username: 'deploy',
          authType: 'key',
          keyAlias: 'laptop',
          groupName: 'General',
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(ValueKey('authKeys.key.${vm.keys.single.id}.edit')));
      await tester.pumpAndSettle();
      expect(find.text('Edit SSH Key'), findsOneWidget);
      await tester.enterText(find.byKey(const ValueKey('authKeys.import.alias')), 'desk');
      await tapVisible(tester, find.byKey(const ValueKey('authKeys.import.save')));

      expect(vm.keys.single.alias, 'desk');
      expect((await repo.getAllServers()).single.authKeyAlias, 'desk');
      expect((await repo.getAllProfiles()).single.keyAlias, 'desk');
      expect(find.text("Updated key 'desk'."), findsOneWidget);
      await finish(tester);
    });

    testWidgets('a pasted private key replaces the key material', (tester) async {
      await pump(tester);
      await repo.insertKey(
        const SshKey(
          id: 0,
          alias: 'old',
          keyType: 'RSA',
          privateKey: 'placeholder',
          publicKey: '',
          fingerprint: 'SHA256:old',
        ),
      );
      await app.start();
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(ValueKey('authKeys.key.${vm.keys.single.id}.edit')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('authKeys.import.private')),
        keys.privateKey,
      );
      await tapVisible(tester, find.byKey(const ValueKey('authKeys.import.save')));

      final stored = (await repo.getAllKeys()).single;
      expect(stored.alias, 'old');
      expect(stored.keyType, 'ED25519');
      expect(stored.fingerprint, isNot('SHA256:old'));
      await finish(tester);
    });
  });

  group('deleting a key', () {
    testWidgets('asks with Kotlin wording first', (tester) async {
      await pump(tester);
      await vm.importKey(alias: 'laptop', privateKey: keys.privateKey);
      await tester.pumpAndSettle();

      final key = vm.keys.single;
      await tester.tap(find.byKey(ValueKey('authKeys.key.${key.id}.delete')));
      await tester.pumpAndSettle();

      expect(find.text('Delete key?'), findsOneWidget);
      expect(
        find.text(
          'Delete SSH key "laptop" from OmniTerm? Hosts relying on it will no longer authenticate.',
        ),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const ValueKey('authKeys.deleteKey.cancel')));
      await tester.pumpAndSettle();
      expect(vm.keys, hasLength(1));

      await tester.tap(find.byKey(ValueKey('authKeys.key.${key.id}.delete')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('authKeys.deleteKey.confirm')));
      await tester.pumpAndSettle();
      expect(vm.keys, isEmpty);
      await finish(tester);
    });

    /// Why `removeKeyIfPresent` in the key integration suites has to loop: each card is keyed by
    /// the row id, so two rows sharing an alias are two cards and one delete leaves one.
    testWidgets('two keys sharing an alias are two cards, and one delete leaves one', (
      tester,
    ) async {
      await pump(tester);
      for (final fingerprint in ['SHA256:first', 'SHA256:second']) {
        await repo.insertKey(
          SshKey(
            id: 0,
            alias: 'laptop',
            keyType: 'ED25519',
            privateKey: keys.privateKey,
            publicKey: keys.publicKey,
            fingerprint: fingerprint,
          ),
        );
      }
      await app.start();
      await tester.pumpAndSettle();

      Finder cardsFor(String alias) => find.ancestor(
        of: find.text(alias),
        matching: find.byWidgetPredicate(
          (w) =>
              w.key is ValueKey<String> &&
              RegExp(r'^authKeys\.key\.\d+$').hasMatch((w.key as ValueKey<String>).value),
        ),
      );

      expect(cardsFor('laptop'), findsNWidgets(2), reason: 'one card per row, not per alias');

      await tester.tap(find.byKey(ValueKey('authKeys.key.${vm.keys.first.id}.delete')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('authKeys.deleteKey.confirm')));
      await tester.pumpAndSettle();

      expect(cardsFor('laptop'), findsOneWidget);
      await finish(tester);
    });
  });

  group('credential profiles', () {
    testWidgets('a password profile is created', (tester) async {
      await pump(tester);

      await choose(tester, 'profile');
      expect(find.text('Create Credential Profile'), findsOneWidget);
      await tester.enterText(find.byKey(const ValueKey('authKeys.profile.name')), 'shared');
      await tester.enterText(find.byKey(const ValueKey('authKeys.profile.username')), 'deploy');
      await tester.enterText(find.byKey(const ValueKey('authKeys.profile.password')), 'hunter2');
      await tapVisible(tester, find.byKey(const ValueKey('authKeys.profile.save')));

      expect(find.text('shared'), findsOneWidget);
      expect(find.text('User: deploy · Auth: password'), findsOneWidget);
      await finish(tester);
    });

    testWidgets('Save Profile waits for name, username and password', (tester) async {
      await pump(tester);
      await choose(tester, 'profile');
      final save = find.byKey(const ValueKey('authKeys.profile.save'));
      expect(tester.widget<FilledButton>(save).onPressed, isNull);
      await tester.enterText(find.byKey(const ValueKey('authKeys.profile.name')), 'shared');
      await tester.enterText(find.byKey(const ValueKey('authKeys.profile.username')), 'deploy');
      await tester.pump();
      expect(tester.widget<FilledButton>(save).onPressed, isNull);
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
      expect(find.text('Password (leave blank to keep current)'), findsOneWidget);
      await finish(tester);
    });

    testWidgets('a key profile says which key it is bound to', (tester) async {
      await pump(tester);
      await repo.insertProfile(
        const CredentialProfile(
          id: 0,
          profileName: 'keyed',
          username: 'deploy',
          authType: 'key',
          keyAlias: 'laptop',
          groupName: 'General',
        ),
      );
      await app.start();
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ValueKey('authKeys.profile.${vm.profiles.single.id}.edit')));
      await tester.pumpAndSettle();
      expect(find.text("Key profile — bound to key 'laptop'."), findsOneWidget);
      expect(find.byKey(const ValueKey('authKeys.profile.password')), findsNothing);
      await finish(tester);
    });

    testWidgets('deleting asks with Kotlin wording first', (tester) async {
      await pump(tester);
      await vm.saveProfile(
        profileName: 'shared',
        username: 'deploy',
        authType: 'password',
        password: 'x',
      );
      await tester.pumpAndSettle();
      final profile = vm.profiles.single;

      await tester.tap(find.byKey(ValueKey('authKeys.profile.${profile.id}.delete')));
      await tester.pumpAndSettle();
      expect(find.text('Delete profile?'), findsOneWidget);
      expect(
        find.text(
          'Delete credential profile "shared"? Hosts using it will lose these credentials.',
        ),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const ValueKey('authKeys.deleteProfile.cancel')));
      await tester.pumpAndSettle();
      expect(vm.profiles, hasLength(1));
      await finish(tester);
    });
  });

  group('trusted host keys', () {
    Future<InMemoryHostKeyStore> pinned() async {
      final store = InMemoryHostKeyStore();
      await store.write(
        '${SshHostKeyTrust.canonicalAlias('10.0.0.9', 2222)}|ssh-ed25519',
        'SHA256:abc',
      );
      return store;
    }

    testWidgets('pinned hosts are listed with their fingerprint', (tester) async {
      await pump(tester, trust: SshHostKeyTrust(await pinned()));
      expect(find.byKey(ValueKey('authKeys.trust.${vm.knownHosts.single.host}')), findsOneWidget);
      expect(find.textContaining('SHA256:abc'), findsOneWidget);
      await finish(tester);
    });

    testWidgets('removing asks with Kotlin wording first', (tester) async {
      final store = await pinned();
      await pump(tester, trust: SshHostKeyTrust(store));

      final host = vm.knownHosts.single;
      await tester.tap(find.byKey(ValueKey('authKeys.trust.${host.host}.revoke')));
      await tester.pumpAndSettle();

      expect(find.text('Remove trusted key?'), findsOneWidget);
      expect(find.textContaining('prompt you to verify and pin the key again'), findsOneWidget);
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

    testWidgets('the address obeys Hide sensitive info, and the fingerprint does not', (
      tester,
    ) async {
      HostDisplay.instance.hideSensitiveInfo = true;
      addTearDown(() => HostDisplay.instance.hideSensitiveInfo = false);
      await pump(tester, trust: SshHostKeyTrust(await pinned()));

      expect(find.textContaining('10.0.0.9'), findsNothing, reason: 'the address must be masked');
      expect(find.textContaining('SHA256:abc'), findsOneWidget);

      await tester.tap(find.byKey(ValueKey('authKeys.trust.${vm.knownHosts.single.host}.revoke')));
      await tester.pumpAndSettle();
      expect(find.textContaining('10.0.0.9'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('authKeys.revoke.cancel')));
      await tester.pumpAndSettle();
      await finish(tester);
    });

    testWidgets('the mask follows the toggle without waiting for a repaint', (tester) async {
      await pump(tester, trust: SshHostKeyTrust(await pinned()));
      expect(find.textContaining('10.0.0.9'), findsOneWidget);

      HostDisplay.instance.hideSensitiveInfo = true;
      addTearDown(() => HostDisplay.instance.hideSensitiveInfo = false);
      await tester.pumpAndSettle();

      expect(find.textContaining('10.0.0.9'), findsNothing);
      await finish(tester);
    });
  });

  group('generating a key', () {
    /// Real generation over a throwaway modulus: the encoding is the part that can be wrong, so
    /// only the key size shrinks.
    Future<GeneratedSshKey> fastGenerator({
      required String alias,
      required String keyType,
      required Set<String> existingAliases,
    }) async => generateSshKeyPair(
      alias: alias,
      keyType: keyType,
      existingAliases: existingAliases,
      bits: 512,
    );

    String fieldText(WidgetTester tester, String key) => tester
        .widget<EditableText>(
          find.descendant(of: find.byKey(ValueKey(key)), matching: find.byType(EditableText)),
        )
        .controller
        .text;

    testWidgets('a generated key is stored, listed, and shown once', (tester) async {
      await pump(tester, keyGenerator: fastGenerator);

      await choose(tester, 'generate');
      expect(find.text('Generate Cryptographic Keypair'), findsOneWidget);
      await tester.enterText(find.byKey(const ValueKey('authKeys.generate.alias')), 'laptop');
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('authKeys.generate.submit')));
      await tester.pumpAndSettle();

      // The result dialog is the only place the private key is ever displayed.
      expect(find.text('Generated Key: laptop'), findsOneWidget);
      final private = fieldText(tester, 'authKeys.generated.private');
      expect(private, startsWith('-----BEGIN RSA PRIVATE KEY-----'));
      final public = fieldText(tester, 'authKeys.generated.public');
      expect(public, startsWith('ssh-rsa '));
      expect(public, endsWith(' laptop'));

      // The install command must carry that exact public line.
      final install = fieldText(tester, 'authKeys.generated.install');
      expect(install, contains(public));
      expect(install, contains('>> ~/.ssh/authorized_keys'));

      await tapVisible(tester, find.byKey(const ValueKey('authKeys.generated.done')));

      expect(find.text('laptop'), findsOneWidget);
      expect(find.textContaining('Crypto: RSA'), findsOneWidget);
      final stored = await repo.getAllKeys();
      expect(stored.single.alias, 'laptop');
      expect(stored.single.privateKey, private);
      await finish(tester);
    });

    testWidgets('a duplicate alias closes the dialog and reports in red, as Kotlin does', (
      tester,
    ) async {
      await pump(tester, keyGenerator: fastGenerator);
      await vm.importKey(alias: 'laptop', privateKey: keys.privateKey);
      await tester.pumpAndSettle();

      await choose(tester, 'generate');
      await tester.enterText(find.byKey(const ValueKey('authKeys.generate.alias')), 'laptop');
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('authKeys.generate.submit')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('authKeys.generate.dialog')), findsNothing);
      final message = tester.widget<Text>(
        find.descendant(
          of: find.byKey(const ValueKey('authKeys.message')),
          matching: find.byType(Text),
        ),
      );
      expect(message.data, 'Key alias already exists.');
      expect(message.style?.color, const Color(0xFFFF0000));
      expect((await repo.getAllKeys()).length, 1);
      await finish(tester);
    });

    testWidgets('generate is disabled until an alias is entered', (tester) async {
      await pump(tester, keyGenerator: fastGenerator);
      await choose(tester, 'generate');
      final submit = tester.widget<FilledButton>(
        find.byKey(const ValueKey('authKeys.generate.submit')),
      );
      expect(submit.onPressed, isNull);
      await finish(tester);
    });
  });
}

class _DelayedProfileRepository extends AppRepository {
  _DelayedProfileRepository(super.db, super.secrets);
  final release = Completer<void>();
  var calls = 0;

  @override
  Future<int> insertProfile(CredentialProfile profile) async {
    calls++;
    await release.future;
    return super.insertProfile(profile);
  }
}
