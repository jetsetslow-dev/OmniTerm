import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omniterm/data/ssh/secure_host_key_store.dart';
import 'package:omniterm/data/ssh/ssh_host_key_trust.dart';
import 'package:omniterm/ui/theme/theme.dart';
import 'package:omniterm/ui/widgets/host_key_approval_host.dart';

import 'support/fake_secure_storage.dart';

void main() {
  group('the prompt', () {
    late SshHostKeyTrust trust;

    /// Starts a check and records its verdict when it settles.
    ///
    /// The verdict is captured through a callback rather than awaited in the test body: the trust
    /// store's commit path is several microtask hops long, and awaiting it directly stalls inside
    /// the widget tester's fake-async zone, which only drains between pumps.
    ({HostKeyVerdict? Function() verdict}) check(
      SshHostKeyTrust trust, {
      required String host,
      String keyType = 'ssh-ed25519',
      required String fingerprint,
    }) {
      HostKeyVerdict? result;
      unawaited(trust
          .check(host: host, port: 22, keyType: keyType, fingerprint: fingerprint)
          .then((v) { debugPrint('DBG verdict=\$v'); result = v; }));
      return (verdict: () => result);
    }

    /// Pumps until the recorded verdict lands.
    ///
    /// The trust store's decision is several awaits deep — the dialog's own route future, then the
    /// commit lock — and how many of those a single `pumpAndSettle` drains is not something a test
    /// should be asserting on. Pumping until the value arrives tests the outcome, not the plumbing.
    Future<HostKeyVerdict?> settled(
      WidgetTester tester,
      ({HostKeyVerdict? Function() verdict}) recorded,
    ) async {
      for (var i = 0; i < 50 && recorded.verdict() == null; i++) {
        await tester.pump(const Duration(milliseconds: 10));
      }
      return recorded.verdict();
    }

    Future<void> pump(WidgetTester tester) async {
      // Built inside the test body rather than in `setUp`: the trust store's commit lock chains
      // onto a Future created at construction time, and a Future created in `setUp` belongs to the
      // outer zone, so its continuations never run under the widget tester's clock.
      trust = SshHostKeyTrust(InMemoryHostKeyStore());
      await tester.pumpWidget(
        MaterialApp(
          theme: omniTheme(OmniThemeMode.dark, Brightness.dark),
          home: HostKeyApprovalHost(
            trust: trust,
            child: const Scaffold(body: SizedBox.expand()),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('an unknown host raises a prompt showing the fingerprint', (tester) async {
      await pump(tester);

      final verdict = check(trust, host: 'nas.local', keyType: 'ssh-ed25519', fingerprint: 'SHA256:abcdef');
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('hostKey.dialog')), findsOneWidget);
      // The host is deliberately not masked: the user is authenticating this specific machine
      // against its fingerprint, so hiding the identity would defeat the decision being asked.
      expect(find.text('nas.local'), findsOneWidget);
      expect(find.text('SHA256:abcdef'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('hostKey.trust')));
      await tester.pumpAndSettle();
      expect(await settled(tester, verdict), HostKeyVerdict.ok);
    });

    testWidgets('rejecting refuses the connection and pins nothing', (tester) async {
      await pump(tester);

      final verdict = check(trust, host: 'nas.local', keyType: 'ssh-ed25519', fingerprint: 'SHA256:abcdef');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('hostKey.reject')));
      await tester.pumpAndSettle();

      expect(await settled(tester, verdict), HostKeyVerdict.notIncluded);
      expect(await trust.hasPinnedKey('nas.local', 22), isFalse,
          reason: 'a refused key must not be remembered as trusted');
    });

    testWidgets('dismissing by tapping outside counts as a refusal', (tester) async {
      // Not "an accident to prevent": making the dialog inescapable would push a user who does not
      // understand it toward the accept button.
      await pump(tester);

      final verdict = check(trust, host: 'nas.local', keyType: 'ssh-ed25519', fingerprint: 'SHA256:abcdef');
      await tester.pumpAndSettle();
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();

      expect(await settled(tester, verdict), HostKeyVerdict.notIncluded);
    });

    testWidgets('two hosts are asked about one at a time', (tester) async {
      // Stacked dialogs would let a user approve one host's fingerprint while reading another's.
      await pump(tester);

      final first = check(trust, host: 'a.local', keyType: 'ssh-ed25519', fingerprint: 'SHA256:aaa');
      final second = check(trust, host: 'b.local', keyType: 'ssh-ed25519', fingerprint: 'SHA256:bbb');
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('hostKey.dialog')), findsOneWidget);
      expect(find.text('a.local'), findsOneWidget);
      expect(find.text('b.local'), findsNothing);

      await tester.tap(find.byKey(const ValueKey('hostKey.reject')));
      await tester.pumpAndSettle();

      expect(find.text('b.local'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('hostKey.trust')));
      await tester.pumpAndSettle();

      expect(await settled(tester, first), HostKeyVerdict.notIncluded);
      expect(await settled(tester, second), HostKeyVerdict.ok);
    });

    testWidgets('an already-trusted host is never asked about again', (tester) async {
      await pump(tester);

      final first = check(trust, host: 'nas.local', keyType: 'ssh-ed25519', fingerprint: 'SHA256:abcdef');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('hostKey.trust')));
      await tester.pumpAndSettle();
      expect(await settled(tester, first), HostKeyVerdict.ok);

      final second = check(trust, host: 'nas.local', keyType: 'ssh-ed25519', fingerprint: 'SHA256:abcdef');
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('hostKey.dialog')), findsNothing);
      expect(await settled(tester, second), HostKeyVerdict.ok);
    });

    testWidgets('a changed key is refused outright, never offered for approval', (tester) async {
      // This is the case the whole mechanism exists for. A prompt here would let a user click
      // through the one warning that matters.
      await pump(tester);

      final first = check(trust, host: 'nas.local', keyType: 'ssh-ed25519', fingerprint: 'SHA256:original');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('hostKey.trust')));
      await tester.pumpAndSettle();
      expect(await settled(tester, first), HostKeyVerdict.ok);

      final changed = check(trust, host: 'nas.local', keyType: 'ssh-ed25519', fingerprint: 'SHA256:different');
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('hostKey.dialog')), findsNothing);
      expect(await settled(tester, changed), HostKeyVerdict.changed);
    });

    testWidgets('unmounting answers a pending prompt as a refusal', (tester) async {
      // A completer left hanging would hold the connection attempt open until its timeout.
      await pump(tester);

      final verdict = check(trust, host: 'nas.local', keyType: 'ssh-ed25519', fingerprint: 'SHA256:abcdef');
      await tester.pumpAndSettle();

      await tester.pumpWidget(const MaterialApp(home: Scaffold(body: SizedBox.shrink())));
      await tester.pumpAndSettle();

      expect(await settled(tester, verdict), HostKeyVerdict.notIncluded);
    });

    testWidgets('the verification command names the right key file', (tester) async {
      // A user who does not already know how to check a fingerprint gets a command to run rather
      // than an instruction to "verify" that they will skip.
      await pump(tester);

      check(trust, host: 'nas.local', fingerprint: 'SHA256:abcdef');
      await tester.pumpAndSettle();

      final howTo =
          tester.widget<Text>(find.byKey(const ValueKey('hostKey.howTo'))).data!;
      expect(howTo, contains('ssh_host_ed25519_key.pub'));
      expect(howTo, contains('not over SSH'),
          reason: 'checking over the connection being attacked proves nothing');

      await tester.tap(find.byKey(const ValueKey('hostKey.reject')));
      await tester.pumpAndSettle();
    });

    test('each key type maps to the file the server actually keeps it in', () {
      expect(HostKeyApprovalDialog.hostKeyFile('ssh-ed25519'), 'ssh_host_ed25519_key.pub');
      expect(HostKeyApprovalDialog.hostKeyFile('ecdsa-sha2-nistp256'), 'ssh_host_ecdsa_key.pub');
      expect(HostKeyApprovalDialog.hostKeyFile('ssh-rsa'), 'ssh_host_rsa_key.pub');
      expect(HostKeyApprovalDialog.hostKeyFile('something-new'), 'ssh_host_*_key.pub');
    });

    testWidgets('with no prompt mounted an unknown host fails closed', (tester) async {
      // The default without this widget: unattended code paths must never auto-trust.
      await tester.pumpWidget(const MaterialApp(home: Scaffold(body: SizedBox.shrink())));
      final bare = SshHostKeyTrust(InMemoryHostKeyStore());

      expect(
        await bare.check(
          host: 'nas.local',
          port: 22,
          keyType: 'ssh-ed25519',
          fingerprint: 'SHA256:abcdef',
        ),
        HostKeyVerdict.notIncluded,
      );
    });
  });

  group('the persistent store', () {
    late FakeSecureStorage storage;
    late SecureHostKeyStore store;

    setUp(() {
      storage = FakeSecureStorage(<String, String>{});
      store = SecureHostKeyStore(storage: storage);
    });

    test('namespaces its entries away from the credential secrets', () async {
      await storage.write(key: 'omniterm_secret_key_v2', value: 'the-encryption-key');
      await store.write('nas|ssh-ed25519', 'SHA256:abc');

      expect(await store.readAll(), {'nas|ssh-ed25519': 'SHA256:abc'});
      expect(await store.read('nas|ssh-ed25519'), 'SHA256:abc');
    });

    test('clearing host keys leaves everything else alone', () async {
      // `deleteAll()` on the shared storage would take the encryption key and every saved
      // credential with it. "Forget every host key" must mean exactly that.
      await storage.write(key: 'omniterm_secret_key_v2', value: 'the-encryption-key');
      await store.write('a|ssh-ed25519', 'SHA256:a');
      await store.write('b|ssh-rsa', 'SHA256:b');

      await store.deleteAll();

      expect(await store.readAll(), isEmpty);
      expect(await storage.read(key: 'omniterm_secret_key_v2'), 'the-encryption-key');
    });

    test('a pin survives a round trip through the trust store', () async {
      final trust = SshHostKeyTrust(store);
      await trust.persistApprovedFirstPin(storageKey: 'nas|ssh-ed25519', fingerprint: 'SHA256:abc');

      expect(await SshHostKeyTrust(store).hasPinnedKey('nas', 22), isTrue);
    });
  });
}
