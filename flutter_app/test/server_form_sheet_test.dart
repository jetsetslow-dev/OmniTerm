import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omniterm/data/app_database.dart';
import 'package:omniterm/ui/screens/servers/server_form_sheet.dart';
import 'package:omniterm/ui/screens/servers/server_form_state.dart';
import 'package:omniterm/ui/theme/theme.dart';

/// The sheet is the only way to create a host, so these tests are the check that the app can do its
/// primary job at all — plus that the two security controls survive the trip through the widget.
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
  late List<Server> tested;

  setUp(() {
    savedRows = [];
    tested = [];
  });

  Future<void> pump(
    WidgetTester tester, {
    ServerFormMode mode = ServerFormMode.add,
    Server? source,
    String? testFailure,
    bool withTester = true,
    List<Server> existingServers = const [],
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: omniTheme(OmniThemeMode.dark, Brightness.dark),
        home: Scaffold(
          body: ServerFormSheet(
            mode: mode,
            source: source,
            existingServers: existingServers,
            onSave: (s) async => savedRows.add(s),
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

  Future<void> fillNewHost(WidgetTester tester) async {
    await tester.enterText(find.byKey(const ValueKey('serverForm.name')), 'nas');
    await tester.enterText(find.byKey(const ValueKey('serverForm.host')), '10.0.0.9');
    await tester.enterText(find.byKey(const ValueKey('serverForm.username')), 'root');
    await tester.pumpAndSettle();
  }

  testWidgets('a new host can be created end to end', (tester) async {
    await pump(tester);
    await fillNewHost(tester);

    await tester.tap(find.byKey(const ValueKey('serverForm.test')));
    await tester.pumpAndSettle();
    expect(find.text('Connection succeeded'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('serverForm.save')));
    await tester.pumpAndSettle();

    expect(savedRows, hasLength(1));
    expect(savedRows.single.name, 'nas');
    expect(savedRows.single.host, '10.0.0.9');
    expect(savedRows.single.id, 0, reason: 'a new host must not target an existing row');
  });

  group('SSH compression', () {
    // The switch was live and stored a value the connection never had: this port's SSH library
    // proposes `none` for compression and ships no zlib, while Kotlin negotiates it
    // (`JschSession.kt:85`). Defect 77's rule — do not offer what cannot work — applied to a
    // setting rather than a button.
    /// The row lives on the Advanced tab, which is not built until that tab is selected.
    Future<void> revealCompression(WidgetTester tester) async {
      await tester.tap(find.text('Advanced'));
      await tester.pumpAndSettle();
      await tester.drag(
        find.byKey(const ValueKey('serverForm.tab.advanced')),
        const Offset(0, -300),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('cannot be switched on, and says why', (tester) async {
      await pump(tester);
      await revealCompression(tester);

      final tile = tester.widget<SwitchListTile>(
        find.byKey(const ValueKey('serverForm.compression')),
      );
      expect(
        tile.onChanged,
        isNull,
        reason: 'a switch that cannot take effect must not invite a tap',
      );
      expect(find.textContaining('has no effect'), findsOneWidget);
    });

    testWidgets('a value set by the Kotlin app is shown and saved back unchanged', (tester) async {
      // Disabling the control must not rewrite the row. Someone who turned this on in the Kotlin
      // app still has it in their backup, and it starts working the day the library does.
      await pump(tester, mode: ServerFormMode.edit, source: saved().copyWith(sshCompression: true));
      await revealCompression(tester);

      final tile = tester.widget<SwitchListTile>(
        find.byKey(const ValueKey('serverForm.compression')),
      );
      expect(tile.value, isTrue);

      await tester.tap(find.byKey(const ValueKey('serverForm.test')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('serverForm.save')));
      await tester.pumpAndSettle();

      expect(savedRows.single.sshCompression, isTrue);
    });
  });

  testWidgets('saving is refused until the connection has been tested', (tester) async {
    await pump(tester);
    await fillNewHost(tester);

    await tester.tap(find.byKey(const ValueKey('serverForm.save')));
    await tester.pumpAndSettle();

    expect(savedRows, isEmpty, reason: 'this is what forces the host-key approval');
    expect(find.byKey(const ValueKey('serverForm.error')), findsOneWidget);
  });

  testWidgets('a failed test does not open the save gate', (tester) async {
    await pump(tester, testFailure: 'Connection refused');
    await fillNewHost(tester);

    await tester.tap(find.byKey(const ValueKey('serverForm.test')));
    await tester.pumpAndSettle();
    expect(find.text('Connection refused'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('serverForm.save')));
    await tester.pumpAndSettle();
    expect(savedRows, isEmpty);
  });

  testWidgets('changing the host after a pass forces a retest', (tester) async {
    await pump(tester);
    await fillNewHost(tester);
    await tester.tap(find.byKey(const ValueKey('serverForm.test')));
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const ValueKey('serverForm.host')), '10.0.0.99');
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('serverForm.save')));
    await tester.pumpAndSettle();
    expect(
      savedRows,
      isEmpty,
      reason: 'the new host presents a different key, which was never approved',
    );
  });

  testWidgets('validation blocks an incomplete form and names the missing field', (tester) async {
    await pump(tester);
    await tester.tap(find.byKey(const ValueKey('serverForm.save')));
    await tester.pumpAndSettle();

    expect(find.text('Name is required'), findsOneWidget);
    expect(savedRows, isEmpty);
  });

  testWidgets('the test uses the typed values, not the saved row', (tester) async {
    await pump(tester, mode: ServerFormMode.edit, source: saved());
    await tester.enterText(find.byKey(const ValueKey('serverForm.host')), '10.0.0.77');
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('serverForm.test')));
    await tester.pumpAndSettle();

    expect(tested.single.host, '10.0.0.77');
  });

  group('stored secrets in the widget', () {
    testWidgets('the password field is empty and says a secret is saved', (tester) async {
      await pump(tester, mode: ServerFormMode.edit, source: saved());
      await tester.tap(find.text('Auth'));
      await tester.pumpAndSettle();

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
      expect(find.text('Saved — leave blank to keep'), findsOneWidget);
    });

    testWidgets('leaving the field blank keeps the stored password', (tester) async {
      await pump(tester, mode: ServerFormMode.edit, source: saved());
      await tester.tap(find.byKey(const ValueKey('serverForm.save')));
      await tester.pumpAndSettle();

      expect(savedRows.single.authPassword, 'stored-secret');
      expect(savedRows.single.id, 3, reason: 'an edit updates in place');
    });

    testWidgets('the forget tick clears it, and forces a retest', (tester) async {
      await pump(tester, mode: ServerFormMode.edit, source: saved());
      await tester.tap(find.text('Auth'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('serverForm.password.forget')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('serverForm.save')));
      await tester.pumpAndSettle();
      expect(savedRows, isEmpty, reason: 'the credential changed, so the pass is stale');

      await tester.tap(find.byKey(const ValueKey('serverForm.test')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('serverForm.save')));
      await tester.pumpAndSettle();
      expect(savedRows.single.authPassword, isEmpty);
    });

    testWidgets('no forget tick is offered when nothing is stored', (tester) async {
      await pump(tester);
      await tester.tap(find.text('Auth'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('serverForm.password.forget')), findsNothing);
    });
  });

  testWidgets('all three tabs are reachable', (tester) async {
    await pump(tester);
    for (final (tab, probe) in [
      ('Auth', 'serverForm.authType'),
      ('Advanced', 'serverForm.notes'),
      ('Connect', 'serverForm.host'),
    ]) {
      await tester.tap(find.text(tab));
      await tester.pumpAndSettle();
      expect(find.byKey(ValueKey(probe)), findsOneWidget, reason: 'the $tab tab did not render');
    }
  });

  testWidgets('proxy fields appear only once a proxy is chosen', (tester) async {
    await pump(tester);
    await tester.tap(find.text('Advanced'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('serverForm.proxyHost')), findsNothing);

    await tester.drag(find.byKey(const ValueKey('serverForm.tab.advanced')), const Offset(0, -400));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('serverForm.proxyType')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('SOCKS5').last);
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('serverForm.proxyHost')), findsOneWidget);
  });

  testWidgets('a duplicate seeds the secrets but still faces the gate', (tester) async {
    await pump(tester, mode: ServerFormMode.duplicate, source: saved());
    expect(find.text('Duplicate host'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('serverForm.save')));
    await tester.pumpAndSettle();
    expect(savedRows, isEmpty, reason: 'a copy shares no trust state with its source');

    await tester.tap(find.byKey(const ValueKey('serverForm.test')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('serverForm.save')));
    await tester.pumpAndSettle();

    expect(savedRows.single.id, 0);
    expect(savedRows.single.name, 'nas copy');
    expect(savedRows.single.authPassword, 'stored-secret');
  });

  testWidgets('without a tester wired the button is disabled rather than assuming success', (
    tester,
  ) async {
    await pump(tester, withTester: false);
    final button = tester.widget<OutlinedButton>(find.byKey(const ValueKey('serverForm.test')));
    expect(button.onPressed, isNull);
  });

  /// The duplicate-address warning, ported from `confirmDuplicateHost` in `ui/AppUi.kt:2782`.
  ///
  /// Deliberately a warning and not a validation error: two entries for one machine is a legitimate
  /// setup — a root login and an unprivileged one, say — so the collision is reported and the
  /// decision left with the user.
  group('duplicate address', () {
    /// A host already saved at the address `fillNewHost` types.
    Server existingAt(String address) => saved().copyWith(id: 7, name: 'web-prod', host: address);

    testWidgets('saving a second host at one address warns before storing it', (tester) async {
      await pump(tester, existingServers: [existingAt('10.0.0.9')]);
      await fillNewHost(tester);
      await tester.tap(find.byKey(const ValueKey('serverForm.test')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('serverForm.save')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('serverForm.duplicate.dialog')), findsOneWidget);
      // Naming the clashing host is the point: "duplicate address" alone does not say which one.
      expect(find.textContaining('web-prod'), findsOneWidget);
      expect(find.textContaining('10.0.0.9'), findsWidgets);
      expect(savedRows, isEmpty, reason: 'nothing may be stored before the user answers');
    });

    testWidgets('Review returns to the form without saving', (tester) async {
      await pump(tester, existingServers: [existingAt('10.0.0.9')]);
      await fillNewHost(tester);
      await tester.tap(find.byKey(const ValueKey('serverForm.test')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('serverForm.save')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('serverForm.duplicate.review')));
      await tester.pumpAndSettle();

      expect(savedRows, isEmpty);
      expect(
        find.byKey(const ValueKey('serverForm.save')),
        findsOneWidget,
        reason: 'the sheet stays open so the address can be corrected',
      );
    });

    testWidgets('Save anyway stores the host', (tester) async {
      await pump(tester, existingServers: [existingAt('10.0.0.9')]);
      await fillNewHost(tester);
      await tester.tap(find.byKey(const ValueKey('serverForm.test')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('serverForm.save')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('serverForm.duplicate.saveAnyway')));
      await tester.pumpAndSettle();

      expect(savedRows, hasLength(1));
      expect(savedRows.single.host, '10.0.0.9');
    });

    testWidgets('the match ignores case and surrounding space', (tester) async {
      await pump(tester, existingServers: [existingAt('  NAS.LOCAL ')]);
      await tester.enterText(find.byKey(const ValueKey('serverForm.name')), 'second');
      await tester.enterText(find.byKey(const ValueKey('serverForm.host')), 'nas.local');
      await tester.enterText(find.byKey(const ValueKey('serverForm.username')), 'root');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('serverForm.test')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('serverForm.save')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('serverForm.duplicate.dialog')), findsOneWidget);
    });

    testWidgets('a distinct address saves without a warning', (tester) async {
      await pump(tester, existingServers: [existingAt('10.0.0.2')]);
      await fillNewHost(tester);
      await tester.tap(find.byKey(const ValueKey('serverForm.test')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('serverForm.save')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('serverForm.duplicate.dialog')), findsNothing);
      expect(savedRows, hasLength(1));
    });

    testWidgets('editing a host does not warn about its own address', (tester) async {
      // Otherwise every edit of an existing host would warn about itself.
      final existing = saved();
      await pump(tester, mode: ServerFormMode.edit, source: existing, existingServers: [existing]);
      await tester.tap(find.byKey(const ValueKey('serverForm.save')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('serverForm.duplicate.dialog')), findsNothing);
      expect(savedRows, hasLength(1));
    });
  });
}
