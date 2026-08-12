import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:omniterm/main.dart' as app;

import '../test/support/ed25519_fixture.dart';

/// The SSH-key import sheet, end to end on a device.
///
/// **This flow exists because the manual walk could not do it.** A PEM cannot be typed with
/// `adb shell input text` — it mangles spaces, drops `+` and `/`, and has no way to send a newline
/// into a multi-line field — and Android 15 has no `cmd clipboard`. So the one screen that gets a
/// private key into the app was the last piece of the port never exercised on a device, even though
/// key authentication itself was proven at the transport level.
///
/// The key is generated fresh at setup (see `test/support/ed25519_fixture.dart`) rather than
/// committed. It is a *real* Ed25519 key, so the parser is exercised for real, and it authenticates
/// to nothing.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late final String privateKey;
  late final String publicKey;

  /// What `ssh-keygen -lf` would print for [publicKey].
  ///
  /// Computed here from the wire blob rather than read back from the app, and deliberately not via
  /// `sshPublicKeyFingerprint`: the point of showing a fingerprint is that it can be compared with
  /// what the *host* reports, so an expectation built from the app's own implementation would agree
  /// with any bug it happens to contain.
  late final String fingerprint;

  setUpAll(() async {
    final keys = await generateEd25519Fixture(comment: 'omniterm-e2e-throwaway');
    privateKey = keys.privateKey;
    publicKey = keys.publicKey;
    final blob = base64.decode(publicKey.split(RegExp(r'\s+'))[1]);
    fingerprint = 'SHA256:${base64.encode(sha256.convert(blob).bytes).replaceAll('=', '')}';
  });

  /// The alias every test here uses. Fixed rather than randomised so a run that dies half way leaves
  /// something the next run can recognise and clear, instead of accumulating debris.
  const alias = 'e2e-import-key';

  /// Matches the card a stored key is drawn in, without knowing the row id the database handed it.
  Finder keyCard(String forAlias) => find.ancestor(
    of: find.text(forAlias),
    matching: find.byWidgetPredicate((w) {
      final key = w.key;
      return key is ValueKey<String> &&
          key.value.startsWith('authKeys.key.') &&
          !key.value.endsWith('.delete') &&
          !key.value.endsWith('.rename');
    }),
  );

  Finder deleteButtonFor(String forAlias) => find.descendant(
    of: keyCard(forAlias),
    matching: find.byWidgetPredicate((w) {
      final key = w.key;
      return key is ValueKey<String> && key.value.endsWith('.delete');
    }),
  );

  Future<void> launch(WidgetTester tester) async {
    app.main();
    await tester.pumpAndSettle(const Duration(seconds: 2));
  }

  Future<void> openAuthKeys(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('nav.tools')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('tools.authKeys')));
    await tester.pumpAndSettle();
  }

  Future<void> openImportSheet(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('authKeys.importKey')));
    await tester.pumpAndSettle();
  }

  /// Deletes the test key if an earlier run left one behind.
  ///
  /// A device carries its database between runs, so a suite that only cleans up on the happy path
  /// passes once and then fails on "Key alias already exists." for whoever runs it next.
  Future<void> removeKeyIfPresent(WidgetTester tester) async {
    if (keyCard(alias).evaluate().isEmpty) return;
    await tester.ensureVisible(deleteButtonFor(alias).first);
    await tester.pumpAndSettle();
    await tester.tap(deleteButtonFor(alias).first);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('authKeys.deleteKey.confirm')));
    await tester.pumpAndSettle();
  }

  testWidgets('the sheet opens and offers the fields a key needs', (tester) async {
    await launch(tester);
    await openAuthKeys(tester);
    await openImportSheet(tester);

    expect(find.byKey(const ValueKey('authKeys.import.alias')), findsOneWidget);
    expect(find.byKey(const ValueKey('authKeys.import.private')), findsOneWidget);
    expect(find.byKey(const ValueKey('authKeys.import.public')), findsOneWidget);
    expect(find.byKey(const ValueKey('authKeys.import.save')), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(find.byKey(const ValueKey('authKeys.import.close')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('authKeys.import.save')), findsNothing);
  });

  testWidgets('a real PEM is accepted, and the key it produces is the right one', (tester) async {
    // The whole point: multi-line key material typed through the framework, which `adb` cannot do.
    await launch(tester);
    await openAuthKeys(tester);
    await removeKeyIfPresent(tester);

    await openImportSheet(tester);
    await tester.enterText(find.byKey(const ValueKey('authKeys.import.alias')), alias);
    await tester.enterText(find.byKey(const ValueKey('authKeys.import.private')), privateKey);
    await tester.enterText(find.byKey(const ValueKey('authKeys.import.public')), publicKey);
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('authKeys.import.save')));
    await tester.pumpAndSettle(const Duration(seconds: 2));

    // A successful import closes the sheet; one that reports a failure keeps it open.
    expect(
      find.byKey(const ValueKey('authKeys.import.error')),
      findsNothing,
      reason: 'a valid ed25519 key was refused',
    );
    expect(keyCard(alias), findsOneWidget, reason: 'the imported key must be listed');

    // Not just "a key appeared" — the *right* key. The type comes from the public line and the
    // fingerprint is the one `ssh-keygen -lf` prints for it, which is the only reason showing a
    // fingerprint is worth anything: it is there to be compared against what the host reports.
    expect(
      find.descendant(of: keyCard(alias), matching: find.text('ED25519')),
      findsOneWidget,
      reason: 'the key type must come from the public line, not be guessed',
    );
    expect(
      find.descendant(of: keyCard(alias), matching: find.text(fingerprint)),
      findsOneWidget,
      reason: 'the fingerprint shown must be the one ssh-keygen -lf prints for this key',
    );

    await removeKeyIfPresent(tester);
    expect(keyCard(alias), findsNothing, reason: 'the flow must leave the device as it found it');
  });

  testWidgets('rubbish is rejected with a reason, not silently stored', (tester) async {
    // A key that fails to parse must be refused at import. Storing it would turn one bad paste into
    // an auth failure on every host that later selects it, with nothing pointing back at the cause.
    await launch(tester);
    await openAuthKeys(tester);
    await openImportSheet(tester);

    await tester.enterText(find.byKey(const ValueKey('authKeys.import.alias')), 'not-a-key');
    await tester.enterText(
      find.byKey(const ValueKey('authKeys.import.private')),
      'this is not a private key',
    );
    await tester.pumpAndSettle();

    // Put the keyboard away before reaching for Import.
    //
    // On the phone this test failed while passing in isolation, and passing on the emulator. The
    // button was present, enabled and still labelled "Import" ten seconds after the tap, and nothing
    // had been stored: the tap was landing on the soft keyboard, which the previous test's typing
    // had left up and which covers the bottom of the sheet. `ensureVisible` cannot help — it scrolls
    // within the sheet, and the IME is an overlay outside it. Run alone the app has just started, no
    // field has been focused, and the button is in the clear, which is exactly why running one test
    // to reproduce a suite failure can disprove the wrong thing.
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const ValueKey('authKeys.import.save')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('authKeys.import.save')));

    // Bounded rather than a fixed settle: parsing and the failure it produces are asynchronous, and
    // a fixed wait that is long enough on an emulator is a guess everywhere else.
    for (var i = 0; i < 100; i++) {
      if (find.byKey(const ValueKey('authKeys.import.error')).evaluate().isNotEmpty) break;
      await tester.pump(const Duration(milliseconds: 100));
    }

    // The sheet stays open, carrying the parser's own reason — not a shrug, and not silence.
    final error = tester.widget<Text>(find.byKey(const ValueKey('authKeys.import.error'))).data!;
    expect(error, isNotEmpty);
    expect(error.toLowerCase(), isNot(contains('null')));

    await tester.tap(find.byKey(const ValueKey('authKeys.import.close')));
    await tester.pumpAndSettle();
    expect(keyCard('not-a-key'), findsNothing, reason: 'it must not have been stored');
  });
}
