import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:omniterm/main.dart' as app;

/// The SSH-key import sheet, end to end on a device.
///
/// **This flow exists because the manual walk could not do it.** A PEM cannot be typed with
/// `adb shell input text` — it mangles spaces, drops `+` and `/`, and has no way to send a newline
/// into a multi-line field — and Android 15 has no `cmd clipboard`. So the one screen that gets a
/// private key into the app was the last piece of the port never exercised on a device, even though
/// key authentication itself was proven at the transport level.
///
/// The key below is a throwaway generated for this file with `ssh-keygen -t ed25519`. It is a *real*
/// key, so the parser is exercised for real, and it authenticates to nothing.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  const privateKey = '''
-----BEGIN OPENSSH PRIVATE KEY-----
b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW
QyNTUxOQAAACD/DC1nUfSsET25C6qvDOcq0cjnn9rScwAeStiXe2SueAAAAKDLM+ztyzPs
7QAAAAtzc2gtZWQyNTUxOQAAACD/DC1nUfSsET25C6qvDOcq0cjnn9rScwAeStiXe2SueA
AAAEDeMizvL4STYWYAG+8DUTwk2lbLStAAUoPlBmoRE1mNdv8MLWdR9KwRPbkLqq8M5yrR
yOef2tJzAB5K2Jd7ZK54AAAAFm9tbml0ZXJtLWUyZS10aHJvd2F3YXkBAgMEBQYH
-----END OPENSSH PRIVATE KEY-----''';

  const publicKey =
      'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIP8MLWdR9KwRPbkLqq8M5yrRyOef2tJzAB5K2Jd7ZK54 omniterm-e2e-throwaway';

  /// Exactly what `ssh-keygen -lf` prints for the public line above. Asserting on this rather than
  /// on "some fingerprint appeared" is the whole reason the app shows one: it exists to be compared
  /// against what the host reports, so a value only this app can produce would be useless.
  const fingerprint = 'SHA256:a9bHeBwcxdH8Y1RVQQQOAhysoRaDlOoMs+0kolWECxU';

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

    await tester.tap(find.byKey(const ValueKey('authKeys.import.save')));
    await tester.pumpAndSettle(const Duration(seconds: 2));

    // The sheet stays open, carrying the parser's own reason — not a shrug, and not silence.
    final error = tester.widget<Text>(find.byKey(const ValueKey('authKeys.import.error'))).data!;
    expect(error, isNotEmpty);
    expect(error.toLowerCase(), isNot(contains('null')));

    await tester.tap(find.byKey(const ValueKey('authKeys.import.close')));
    await tester.pumpAndSettle();
    expect(keyCard('not-a-key'), findsNothing, reason: 'it must not have been stored');
  });
}
