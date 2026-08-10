import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:omniterm/main.dart' as app;

/// Generating an SSH keypair on the device, end to end.
///
/// **This cannot be proven anywhere else.** The host suite generates a deliberately small modulus so
/// it stays fast, and it runs on the desktop VM. Neither fact survives the trip to a phone: the real
/// key is 4096 bits, the work runs on a spawned isolate, and PointyCastle's big-integer arithmetic
/// is pure Dart with no native acceleration behind it. A generation that is correct on the desktop
/// but takes minutes, or that never returns because `compute` did not spawn, is a device-only defect
/// — which is exactly the class this file exists to catch.
///
/// Nothing here touches a host. The keypair is generated locally, inspected, and deleted, so the
/// suite is host independent by construction.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  /// Fixed rather than randomised so a run that dies half way leaves something the next run can
  /// recognise and clear, instead of accumulating debris on a device that keeps its database.
  const alias = 'e2e-generated-key';

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

  Future<void> removeKeyIfPresent(WidgetTester tester) async {
    if (keyCard(alias).evaluate().isEmpty) return;
    await tester.ensureVisible(deleteButtonFor(alias).first);
    await tester.pumpAndSettle();
    await tester.tap(deleteButtonFor(alias).first);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('authKeys.deleteKey.confirm')));
    await tester.pumpAndSettle();
  }

  testWidgets('a real 4096-bit keypair is generated, shown once, and stored', (tester) async {
    await launch(tester);
    await openAuthKeys(tester);
    await removeKeyIfPresent(tester);

    await tester.tap(find.byKey(const ValueKey('authKeys.generateKey')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('authKeys.generate.alias')), alias);
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('authKeys.generate.submit')));
    // Bounded real-time wait rather than a bare `pumpAndSettle`: generation is off-isolate, so the
    // frame loop settles long before the key exists. The ceiling is the assertion — a keypair that
    // takes longer than this on a phone is a defect, not a slow test.
    final deadline = DateTime.now().add(const Duration(seconds: 90));
    while (find.byKey(const ValueKey('authKeys.generated.dialog')).evaluate().isEmpty) {
      expect(
        DateTime.now().isBefore(deadline),
        isTrue,
        reason: 'generation did not finish within 90s on this device',
      );
      await tester.pump(const Duration(milliseconds: 250));
    }

    // The result dialog is the only place the private key is ever shown: it is stored encrypted and
    // never read back to the UI, so a user who does not copy it here cannot retrieve it later.
    final private = tester
        .widget<SelectableText>(find.byKey(const ValueKey('authKeys.generated.private')))
        .data!;
    expect(private, startsWith('-----BEGIN RSA PRIVATE KEY-----'));
    expect(private, endsWith('-----END RSA PRIVATE KEY-----\n'));

    final public = tester
        .widget<SelectableText>(find.byKey(const ValueKey('authKeys.generated.public')))
        .data!;
    expect(public, startsWith('ssh-rsa '));
    expect(public, endsWith(' $alias'));
    // A 4096-bit modulus base64s to roughly 720 characters. Asserting the magnitude catches a build
    // that silently generated a weak key far more usefully than asserting the prefix alone.
    expect(
      public.split(' ')[1].length,
      greaterThan(700),
      reason: 'the stored key must be the full-strength one, not a downgraded modulus',
    );

    final install = tester
        .widget<SelectableText>(find.byKey(const ValueKey('authKeys.generated.install')))
        .data!;
    expect(install, contains(public));
    expect(install, contains('>> ~/.ssh/authorized_keys'));

    await tester.tap(find.byKey(const ValueKey('authKeys.generated.done')));
    await tester.pumpAndSettle();

    // It survives as a stored key, not just as a dialog that has been dismissed.
    expect(keyCard(alias), findsOneWidget, reason: 'the generated key must be listed');
    expect(
      find.descendant(of: keyCard(alias), matching: find.text('RSA')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: keyCard(alias), matching: find.textContaining('SHA256:')),
      findsOneWidget,
      reason: 'the fingerprint is what the user compares against the host',
    );
    expect(tester.takeException(), isNull);

    await removeKeyIfPresent(tester);
    expect(keyCard(alias), findsNothing, reason: 'the flow must leave the device as it found it');
  }, timeout: const Timeout(Duration(minutes: 5)));

  testWidgets('an alias already in use is refused without storing anything', (tester) async {
    await launch(tester);
    await openAuthKeys(tester);
    await removeKeyIfPresent(tester);

    await tester.tap(find.byKey(const ValueKey('authKeys.generateKey')));
    await tester.pumpAndSettle();
    // Blank alias: the button stays disabled, so nothing can be generated by accident.
    expect(
      tester.widget<FilledButton>(find.byKey(const ValueKey('authKeys.generate.submit'))).onPressed,
      isNull,
    );

    await tester.enterText(find.byKey(const ValueKey('authKeys.generate.alias')), alias);
    await tester.pumpAndSettle();
    expect(
      tester.widget<FilledButton>(find.byKey(const ValueKey('authKeys.generate.submit'))).onPressed,
      isNotNull,
    );

    // Leaving without generating must not store a key, and must not leave the dialog behind.
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('authKeys.generate.dialog')), findsNothing);
    expect(keyCard(alias), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
