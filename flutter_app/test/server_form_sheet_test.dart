import 'dart:async';
import 'package:drift/drift.dart' show Value;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omniterm/data/app_database.dart';
import 'package:omniterm/l10n/app_localizations.dart';
import 'package:omniterm/ui/screens/servers/server_form_sheet.dart';
import 'package:omniterm/ui/screens/servers/server_form_state.dart';
import 'package:omniterm/ui/theme/theme.dart';
import 'package:omniterm/ui/widgets/popup_scroll_behavior.dart';

/// The dialog is the only way to create a host, so these tests are the check that the app can do
/// its primary job at all — plus that the two security controls survive the trip through the
/// widget. It is Kotlin's `AddServerSheet` wizard: Connection → Credentials → Advanced.
void main() {
  Server saved() => Server(
    id: 3,
    name: 'nas',
    host: '10.0.0.2',
    port: 2222,
    username: 'root',
    serverColor: 'Default',
    authType: 'password',
    authPassword: 'stored-secret',
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

  late List<Server> savedRows;
  late List<bool> createdProfiles;
  late List<Server> tested;

  setUp(() {
    savedRows = [];
    createdProfiles = [];
    tested = [];
  });

  Future<void> pump(
    WidgetTester tester, {
    ServerFormMode mode = ServerFormMode.add,
    Server? source,
    String? testFailure,
    bool withTester = true,
    List<Server> existingServers = const [],
    List<CredentialProfile> savedProfiles = const [],
    ServerSaver? onSave,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: omniTheme(OmniThemeMode.dark, Brightness.dark),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: ServerFormSheet(
            mode: mode,
            source: source,
            existingServers: existingServers,
            savedProfiles: savedProfiles,
            onSave:
                onSave ??
                (s, {createProfile = false}) async {
                  savedRows.add(s);
                  createdProfiles.add(createProfile);
                },
            onTestConnection: withTester
                ? (candidate) async {
                    tested.add(candidate);
                    return testFailure;
                  }
                : null,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> tab(WidgetTester tester, String which) async {
    // The tab row scrolls with the step content, as Kotlin's does.
    await tester.ensureVisible(find.byKey(ValueKey('serverForm.tab.$which')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ValueKey('serverForm.tab.$which')));
    await tester.pumpAndSettle();
  }

  /// Name and address on Connection, username on Credentials — where Kotlin puts them.
  Future<void> fillNewHost(WidgetTester tester, {String host = '10.0.0.9'}) async {
    await tester.enterText(find.byKey(const ValueKey('serverForm.name')), 'nas');
    await tester.enterText(find.byKey(const ValueKey('serverForm.host')), host);
    await tab(tester, 'auth');
    await tester.enterText(find.byKey(const ValueKey('serverForm.username')), 'root');
    await tester.pumpAndSettle();
  }

  Future<void> testConnection(WidgetTester tester) async {
    await tab(tester, 'auth');
    await tester.ensureVisible(find.byKey(const ValueKey('serverForm.test')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('serverForm.test')));
    await tester.pumpAndSettle();
  }

  /// Save lives on the last step, as in Kotlin.
  Future<void> save(WidgetTester tester) async {
    await tab(tester, 'advanced');
    await tester.ensureVisible(find.byKey(const ValueKey('serverForm.save')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('serverForm.save')));
    await tester.pumpAndSettle();
  }

  testWidgets('it is Kotlin\'s wizard: titled, three steps, Next then Save Server', (tester) async {
    await pump(tester);
    expect(find.text('Add Linux Remote Host'), findsOneWidget);
    expect(find.text('Connection'), findsOneWidget);
    expect(find.text('Credentials'), findsOneWidget);
    expect(find.text('Advanced'), findsOneWidget);
    expect(find.text('Display Name (Unique)'), findsOneWidget);
    expect(find.text('IP Address / Hostname'), findsOneWidget);
    expect(find.text('SSH Port'), findsOneWidget);
    expect(find.text('Cancel'), findsOneWidget);
    expect(find.byKey(const ValueKey('serverForm.next')), findsOneWidget);
    expect(find.byKey(const ValueKey('serverForm.save')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('serverForm.next')));
    await tester.pumpAndSettle();
    expect(find.text('Name and host are required.'), findsOneWidget);

    await tester.enterText(find.byKey(const ValueKey('serverForm.name')), 'nas');
    await tester.enterText(find.byKey(const ValueKey('serverForm.host')), '10.0.0.9');
    await tester.tap(find.byKey(const ValueKey('serverForm.next')));
    await tester.pumpAndSettle();
    expect(find.text('SSH Username'), findsOneWidget);
    expect(find.text('Back'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('serverForm.next')));
    await tester.pumpAndSettle();
    expect(find.text('SSH username is required.'), findsOneWidget);

    await tester.enterText(find.byKey(const ValueKey('serverForm.username')), 'root');
    await tester.tap(find.byKey(const ValueKey('serverForm.next')));
    await tester.pumpAndSettle();
    expect(find.text('Server Notes'), findsOneWidget);
    expect(find.text('Save Server'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('serverForm.back')));
    await tester.pumpAndSettle();
    expect(find.text('SSH Username'), findsOneWidget, reason: 'Back returns to the previous step');
  });

  testWidgets('saving is visible, blocks repeat taps and keeps a failed draft open', (
    tester,
  ) async {
    final pending = Completer<void>();
    var calls = 0;
    await pump(
      tester,
      mode: ServerFormMode.edit,
      source: saved(),
      onSave: (_, {createProfile = false}) {
        calls++;
        return pending.future;
      },
    );
    // The save never completes here, so the spinner runs: pump frames, never settle.
    await tab(tester, 'advanced');
    await tester.tap(find.byKey(const ValueKey('serverForm.save')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('Saving server…'), findsOneWidget);
    expect(
      tester.widget<FilledButton>(find.byKey(const ValueKey('serverForm.save'))).onPressed,
      isNull,
    );
    expect(calls, 1);
    pending.completeError(StateError('already exists as "Current name"'));
    await tester.pumpAndSettle();
    expect(find.text('Saving server…'), findsNothing);
    expect(find.textContaining('already exists as "Current name"'), findsOneWidget);
    expect(find.byKey(const ValueKey('serverForm.save')), findsOneWidget);
  });

  for (final (orientation, size, keyboardHeight) in [
    ('portrait', const Size(360, 640), 380.0),
    ('landscape', const Size(640, 360), 196.0),
  ]) {
    testWidgets('unverified save stays usable above the keyboard in $orientation', (tester) async {
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          scrollBehavior: const PopupScrollBehavior(),
          theme: omniTheme(OmniThemeMode.dark, Brightness.dark),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (_) => ServerFormSheet(
                    mode: ServerFormMode.add,
                    onSave: (server, {createProfile = false}) async => savedRows.add(server),
                  ),
                ),
                child: const Text('Add host'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Add host'));
      await tester.pumpAndSettle();
      await fillNewHost(tester);
      tester.view.physicalSize = size;
      tester.view.viewInsets = FakeViewPadding(bottom: keyboardHeight);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: 'the host editor must fit above the keyboard');
      await save(tester);
      expect(
        tester.takeException(),
        isNull,
        reason: 'the unverified decision must fit above the keyboard',
      );
      final dialog = find.byKey(const ValueKey('serverForm.unverified.dialog'));
      expect(dialog, findsOneWidget);
      await tester.ensureVisible(find.byKey(const ValueKey('serverForm.unverified.review')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('serverForm.unverified.review')).hitTestable(),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('serverForm.unverified.saveAnyway')).hitTestable(),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('serverForm.unverified.review')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: 'Review must return to a usable layout');
      expect(savedRows, isEmpty);
      expect(find.byKey(const ValueKey('serverForm.tabs')), findsOneWidget);
    });
  }

  testWidgets('an identical login is rejected without offering Save anyway', (tester) async {
    await pump(
      tester,
      existingServers: [saved().copyWith(name: 'Current name', host: '10.0.0.9', port: 22)],
    );
    await fillNewHost(tester);
    await save(tester);
    expect(find.textContaining('already exist as "Current name"'), findsOneWidget);
    expect(find.byKey(const ValueKey('serverForm.duplicate.dialog')), findsNothing);
    expect(find.byKey(const ValueKey('serverForm.unverified.dialog')), findsNothing);
    expect(savedRows, isEmpty);
  });

  testWidgets('a profile can be selected and supplies the SSH username', (tester) async {
    const profile = CredentialProfile(
      id: 9,
      profileName: 'Fixture login',
      username: 'deploy',
      authType: 'password',
      password: 'fixture secret',
      groupName: 'General',
    );
    await pump(tester, savedProfiles: [profile]);
    await fillNewHost(tester);
    await tester.enterText(find.byKey(const ValueKey('serverForm.username')), '');
    await tester.tap(find.byKey(const ValueKey('serverForm.authType.profile')));
    await tester.pumpAndSettle();
    expect(find.text('Provided by the selected profile'), findsOneWidget);
    await tester.ensureVisible(find.byKey(const ValueKey('serverForm.profile.9')));
    await tester.tap(find.byKey(const ValueKey('serverForm.profile.9')));
    await tester.pumpAndSettle();
    await testConnection(tester);
    await save(tester);
    expect(savedRows.single.authType, 'profile');
    expect(savedRows.single.authProfileId, 9);
    expect(savedRows.single.username, isEmpty, reason: 'the profile owns the SSH username');
  });

  testWidgets('different profile names cannot disguise an existing SSH login', (tester) async {
    const profile = CredentialProfile(
      id: 9,
      profileName: 'New profile name',
      username: 'root',
      authType: 'password',
      password: 'fixture secret',
      groupName: 'General',
    );
    await pump(
      tester,
      mode: ServerFormMode.edit,
      source: saved().copyWith(
        id: 8,
        name: 'Edited row',
        authType: 'profile',
        authProfileId: const Value(9),
        username: '',
      ),
      savedProfiles: [profile],
      existingServers: [saved()],
    );
    await save(tester);
    expect(find.textContaining('already exist as "nas"'), findsOneWidget);
    expect(savedRows, isEmpty);
  });

  testWidgets('a new host can be created end to end', (tester) async {
    await pump(tester);
    await fillNewHost(tester);

    await testConnection(tester);
    expect(find.text('Connection OK'), findsOneWidget);

    await save(tester);

    expect(savedRows, hasLength(1));
    expect(savedRows.single.name, 'nas');
    expect(savedRows.single.host, '10.0.0.9');
    expect(savedRows.single.id, 0, reason: 'a new host must not target an existing row');
    expect(createdProfiles.single, isFalse);
  });

  testWidgets('Save securely to Credential Store asks for a reusable profile', (tester) async {
    await pump(tester);
    await fillNewHost(tester);
    await tester.enterText(
      find.descendant(
        of: find.byKey(const ValueKey('serverForm.password')),
        matching: find.byType(EditableText),
      ),
      'pw',
    );
    expect(
      find.text(
        'Either way the password is stored encrypted on this device so OmniTerm can reconnect; '
        'the Credential Store just makes it reusable across hosts.',
      ),
      findsOneWidget,
    );
    await tester.ensureVisible(find.byKey(const ValueKey('serverForm.saveProfile')));
    await tester.tap(find.byKey(const ValueKey('serverForm.saveProfile')));
    await tester.pumpAndSettle();
    expect(
      find.text('A new credentials profile will be built for this connection automatically.'),
      findsOneWidget,
    );
    await testConnection(tester);
    await save(tester);
    expect(createdProfiles.single, isTrue);
  });

  group('Advanced step', () {
    testWidgets('compression is Kotlin\'s checkbox and saves', (tester) async {
      await pump(tester);
      await tab(tester, 'advanced');
      expect(find.text('Use SSH Payload compression'), findsOneWidget);
      final box = find.byKey(const ValueKey('serverForm.compression'));
      await tester.ensureVisible(box);
      expect(tester.widget<Checkbox>(box).value, isFalse);
      await tester.tap(box);
      await tester.pumpAndSettle();
      expect(tester.widget<Checkbox>(box).value, isTrue);
    });

    testWidgets('a value set by the Kotlin app is shown and saved back unchanged', (tester) async {
      await pump(tester, mode: ServerFormMode.edit, source: saved().copyWith(sshCompression: true));
      await tab(tester, 'advanced');
      expect(
        tester.widget<Checkbox>(find.byKey(const ValueKey('serverForm.compression'))).value,
        isTrue,
      );
      await save(tester);
      expect(savedRows.single.sshCompression, isTrue);
    });

    testWidgets('keep-alive is Kotlin\'s 10s–120s chips', (tester) async {
      await pump(tester);
      await tab(tester, 'advanced');
      expect(find.text('Keep alive interval:'), findsOneWidget);
      for (final s in ['10s', '20s', '30s', '60s', '120s']) {
        expect(find.text(s), findsOneWidget);
      }
      expect(
        tester.widget<FilterChip>(find.byKey(const ValueKey('serverForm.keepAlive.30'))).selected,
        isTrue,
      );
    });
  });

  testWidgets('saving without a test requires an explicit decision', (tester) async {
    await pump(tester);
    await fillNewHost(tester);
    await save(tester);

    expect(savedRows, isEmpty);
    expect(find.text('Save without testing?'), findsOneWidget);
    expect(find.textContaining('host key'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('serverForm.unverified.saveAnyway')));
    await tester.pumpAndSettle();
    expect(savedRows, hasLength(1));
  });

  testWidgets('a failed test can be saved only through Save anyway', (tester) async {
    await pump(tester, testFailure: 'Connection refused');
    await fillNewHost(tester);

    await testConnection(tester);
    expect(find.text('Connection failed: Connection refused'), findsOneWidget);

    await save(tester);
    expect(savedRows, isEmpty);
    expect(find.text('Save after failed check?'), findsOneWidget);
    expect(find.textContaining('Connection refused'), findsWidgets);

    await tester.tap(find.byKey(const ValueKey('serverForm.unverified.saveAnyway')));
    await tester.pumpAndSettle();
    expect(savedRows, hasLength(1));
  });

  testWidgets('changing the host after a pass forces a retest', (tester) async {
    await pump(tester);
    await fillNewHost(tester);
    await testConnection(tester);

    await tab(tester, 'connect');
    await tester.enterText(find.byKey(const ValueKey('serverForm.host')), '10.0.0.99');
    await tester.pumpAndSettle();

    await save(tester);
    expect(
      savedRows,
      isEmpty,
      reason: 'the new host presents a different key, which was never approved',
    );
    expect(find.byKey(const ValueKey('serverForm.unverified.dialog')), findsOneWidget);
  });

  testWidgets('the test uses the typed values, not the saved row', (tester) async {
    await pump(tester, mode: ServerFormMode.edit, source: saved());
    expect(find.text('Edit Linux Remote Host'), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('serverForm.host')), '10.0.0.77');
    await tester.pumpAndSettle();

    await testConnection(tester);

    expect(tested.single.host, '10.0.0.77');
  });

  group('stored secrets in the widget', () {
    testWidgets('the password field is empty and says a secret is saved', (tester) async {
      await pump(tester, mode: ServerFormMode.edit, source: saved());
      await tab(tester, 'auth');

      final field = tester.widget<EditableText>(
        find.descendant(
          of: find.byKey(const ValueKey('serverForm.password')),
          matching: find.byType(EditableText),
        ),
      );
      expect(
        field.controller.text,
        isEmpty,
        reason: 'a saved password must never be rendered into a text field',
      );
      expect(field.obscureText, isTrue);
      expect(
        find.text(
          'A password is saved (never shown here). Leave blank to keep it, or type to replace.',
        ),
        findsOneWidget,
      );
    });

    testWidgets('leaving the field blank keeps the stored password', (tester) async {
      await pump(tester, mode: ServerFormMode.edit, source: saved());
      await save(tester);

      expect(savedRows.single.authPassword, 'stored-secret');
      expect(savedRows.single.id, 3, reason: 'an edit updates in place');
      expect(find.text('Update Server'), findsNothing, reason: 'the dialog closed on save');
    });

    testWidgets('Forget clears it, and forces a retest', (tester) async {
      await pump(tester, mode: ServerFormMode.edit, source: saved());
      await tab(tester, 'auth');
      await tester.ensureVisible(find.byKey(const ValueKey('serverForm.password.forget')));
      await tester.tap(find.byKey(const ValueKey('serverForm.password.forget')));
      await tester.pumpAndSettle();
      expect(find.text('Saved password will be removed when you save.'), findsOneWidget);

      await save(tester);
      expect(savedRows, isEmpty, reason: 'the credential changed, so the pass is stale');
      await tester.tap(find.byKey(const ValueKey('serverForm.unverified.review')));
      await tester.pumpAndSettle();

      await testConnection(tester);
      await save(tester);
      expect(savedRows.single.authPassword, isEmpty);
    });

    testWidgets('no Forget is offered when nothing is stored', (tester) async {
      await pump(tester);
      await tab(tester, 'auth');
      expect(find.byKey(const ValueKey('serverForm.password.forget')), findsNothing);
    });
  });

  testWidgets('proxy fields appear only once a proxy is chosen', (tester) async {
    await pump(tester);
    await tab(tester, 'advanced');
    expect(find.byKey(const ValueKey('serverForm.proxyHost')), findsNothing);

    await tester.ensureVisible(find.byKey(const ValueKey('serverForm.proxyType.socks5')));
    await tester.tap(find.byKey(const ValueKey('serverForm.proxyType.socks5')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('serverForm.proxyHost')), findsOneWidget);
    expect(find.text('Proxy user (optional)'), findsOneWidget);
  });

  testWidgets('a duplicate retains credentials but needs a distinct connection', (tester) async {
    await pump(tester, mode: ServerFormMode.duplicate, source: saved());
    expect(find.text('Duplicate Host'), findsOneWidget);

    await save(tester);
    expect(savedRows, isEmpty);
    expect(find.textContaining('already exist as "nas"'), findsOneWidget);
    await tab(tester, 'connect');
    await tester.enterText(find.byKey(const ValueKey('serverForm.port')), '2223');
    await tester.pumpAndSettle();

    await testConnection(tester);
    await save(tester);

    expect(savedRows.single.id, 0);
    expect(savedRows.single.name, 'nas copy');
    expect(savedRows.single.authPassword, 'stored-secret');
  });

  testWidgets('without a tester wired the button is disabled rather than assuming success', (
    tester,
  ) async {
    await pump(tester, withTester: false);
    await tab(tester, 'auth');
    final button = tester.widget<FilledButton>(find.byKey(const ValueKey('serverForm.test')));
    expect(button.onPressed, isNull);
  });

  /// The duplicate-address warning, ported from `confirmDuplicateHost` in `ui/AppUi.kt`.
  ///
  /// Deliberately a warning and not a validation error: two entries for one machine is a legitimate
  /// setup — a root login and an unprivileged one, say — so the collision is reported and the
  /// decision left with the user.
  group('duplicate address', () {
    Server existingAt(String address) => saved().copyWith(id: 7, name: 'web-prod', host: address);

    testWidgets('saving a second host at one address warns before storing it', (tester) async {
      await pump(tester, existingServers: [existingAt('10.0.0.9')]);
      await fillNewHost(tester);
      await testConnection(tester);
      await save(tester);

      expect(find.byKey(const ValueKey('serverForm.duplicate.dialog')), findsOneWidget);
      expect(find.textContaining('web-prod'), findsOneWidget);
      expect(find.textContaining('10.0.0.9'), findsWidgets);
      expect(savedRows, isEmpty, reason: 'nothing may be stored before the user answers');
    });

    testWidgets('Review returns to the form without saving', (tester) async {
      await pump(tester, existingServers: [existingAt('10.0.0.9')]);
      await fillNewHost(tester);
      await testConnection(tester);
      await save(tester);

      await tester.tap(find.byKey(const ValueKey('serverForm.duplicate.review')));
      await tester.pumpAndSettle();

      expect(savedRows, isEmpty);
      expect(find.byKey(const ValueKey('serverForm.save')), findsOneWidget);
    });

    testWidgets('Save anyway stores the host', (tester) async {
      await pump(tester, existingServers: [existingAt('10.0.0.9')]);
      await fillNewHost(tester);
      await testConnection(tester);
      await save(tester);

      await tester.tap(find.byKey(const ValueKey('serverForm.duplicate.saveAnyway')));
      await tester.pumpAndSettle();

      expect(savedRows, hasLength(1));
      expect(savedRows.single.host, '10.0.0.9');
    });

    testWidgets('the match ignores case and surrounding space', (tester) async {
      await pump(tester, existingServers: [existingAt('  NAS.LOCAL ')]);
      await fillNewHost(tester, host: 'nas.local');
      await testConnection(tester);
      await save(tester);

      expect(find.byKey(const ValueKey('serverForm.duplicate.dialog')), findsOneWidget);
    });

    testWidgets('a distinct address saves without a warning', (tester) async {
      await pump(tester, existingServers: [existingAt('10.0.0.2')]);
      await fillNewHost(tester);
      await testConnection(tester);
      await save(tester);

      expect(find.byKey(const ValueKey('serverForm.duplicate.dialog')), findsNothing);
      expect(savedRows, hasLength(1));
    });

    testWidgets('editing a host does not warn about its own address', (tester) async {
      final existing = saved();
      await pump(tester, mode: ServerFormMode.edit, source: existing, existingServers: [existing]);
      await save(tester);

      expect(find.byKey(const ValueKey('serverForm.duplicate.dialog')), findsNothing);
      expect(savedRows, hasLength(1));
    });
  });
}
