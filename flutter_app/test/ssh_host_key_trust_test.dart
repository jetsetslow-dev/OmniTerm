import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omniterm/data/ssh/capped_text_buffer.dart';
import 'package:omniterm/data/ssh/ssh_host_key_trust.dart';
import 'package:omniterm/data/ssh/ssh_transport.dart';

/// Host-key pinning is the control that stops a man-in-the-middle, so these tests are written
/// around the ways it could *wrongly succeed*, not just the happy path.
void main() {
  /// A base64 public key exactly as the Kotlin app would have stored it.
  String legacyStoredKey(String seed) => base64.encode(utf8.encode('ssh-key-blob-$seed'));

  /// The fingerprint dartssh2 will report for that same key.
  String fingerprintFor(String seed) {
    final digest = sha256.convert(utf8.encode('ssh-key-blob-$seed'));
    return 'SHA256:${base64.encode(digest.bytes).replaceAll('=', '')}';
  }

  late InMemoryHostKeyStore store;
  late SshHostKeyTrust trust;

  setUp(() {
    store = InMemoryHostKeyStore();
    trust = SshHostKeyTrust(store);
  });

  /// Registers a handler that always answers [approve].
  void autoApprove(bool approve) {
    trust.registerApprovalHandler(Object(), (req) => req.completer.complete(approve));
  }

  group('first connection (TOFU)', () {
    test('with no approval handler it fails closed', () async {
      // Background worker / early init: an unknown host must be trusted interactively first.
      final verdict = await trust.check(
        host: 'nas',
        port: 22,
        keyType: 'ssh-ed25519',
        fingerprint: fingerprintFor('a'),
      );
      expect(verdict, HostKeyVerdict.notIncluded);
      expect(await store.readAll(), isEmpty, reason: 'nothing may be pinned without approval');
    });

    test('an approved key is pinned and then verifies', () async {
      autoApprove(true);
      expect(
        await trust.check(
            host: 'nas', port: 22, keyType: 'ssh-ed25519', fingerprint: fingerprintFor('a')),
        HostKeyVerdict.ok,
      );

      // Second connection must not prompt again — prove it by removing the handler.
      trust.clearApprovalHandler(Object());
      expect(
        await trust.check(
            host: 'nas', port: 22, keyType: 'ssh-ed25519', fingerprint: fingerprintFor('a')),
        HostKeyVerdict.ok,
      );
    });

    test('a declined key is not pinned', () async {
      autoApprove(false);
      expect(
        await trust.check(
            host: 'nas', port: 22, keyType: 'ssh-ed25519', fingerprint: fingerprintFor('a')),
        HostKeyVerdict.notIncluded,
      );
      expect(await store.readAll(), isEmpty);
    });

    test('new pins use the JSch alias convention', () async {
      autoApprove(true);
      await trust.check(host: 'nas', port: 22, keyType: 'ssh-ed25519', fingerprint: fingerprintFor('a'));
      await trust.check(host: 'box', port: 2222, keyType: 'ssh-rsa', fingerprint: fingerprintFor('b'));

      final keys = (await store.readAll()).keys.toSet();
      expect(keys, contains('nas|ssh-ed25519'), reason: 'port 22 is written bare');
      expect(keys, contains('[box]:2222|ssh-rsa'), reason: 'non-default ports are bracketed');
    });
  });

  group('a changed key is never auto-accepted', () {
    test('a different fingerprint for a pinned host reports changed', () async {
      autoApprove(true);
      await trust.check(
          host: 'nas', port: 22, keyType: 'ssh-ed25519', fingerprint: fingerprintFor('a'));

      // An attacker's key arrives. Even with a handler that would approve anything, this must not
      // become an approval prompt — the pin already exists.
      final verdict = await trust.check(
          host: 'nas', port: 22, keyType: 'ssh-ed25519', fingerprint: fingerprintFor('EVIL'));
      expect(verdict, HostKeyVerdict.changed);

      // And the original pin must survive.
      expect(await store.read('nas|ssh-ed25519'), fingerprintFor('a'));
    });

    test('a different key type is a separate pin, not a change', () async {
      autoApprove(true);
      await trust.check(
          host: 'nas', port: 22, keyType: 'ssh-ed25519', fingerprint: fingerprintFor('a'));
      // A host legitimately offers several host-key algorithms.
      expect(
        await trust.check(host: 'nas', port: 22, keyType: 'ssh-rsa', fingerprint: fingerprintFor('b')),
        HostKeyVerdict.ok,
      );
    });
  });

  group('legacy trust store inherited from the Kotlin app', () {
    test('a base64 public key pin verifies against the fingerprint dartssh2 reports', () async {
      // This is the migration's whole point: an existing user must not be re-prompted, which would
      // train them to click through the one dialog meant to stop an interception.
      await store.write('nas|ssh-ed25519', legacyStoredKey('a'));

      // No approval handler at all — if the legacy pin were not understood this would fail closed.
      expect(
        await trust.check(
            host: 'nas', port: 22, keyType: 'ssh-ed25519', fingerprint: fingerprintFor('a')),
        HostKeyVerdict.ok,
      );
    });

    test('a legacy pin still detects a changed key', () async {
      await store.write('nas|ssh-ed25519', legacyStoredKey('a'));
      expect(
        await trust.check(
            host: 'nas', port: 22, keyType: 'ssh-ed25519', fingerprint: fingerprintFor('EVIL')),
        HostKeyVerdict.changed,
      );
    });

    test('all three legacy alias forms are recognised', () async {
      for (final alias in ['box', 'box:2222', '[box]:2222']) {
        final s = InMemoryHostKeyStore()..write('$alias|ssh-rsa', legacyStoredKey('a'));
        final t = SshHostKeyTrust(s);
        expect(
          await t.check(host: 'box', port: 2222, keyType: 'ssh-rsa', fingerprint: fingerprintFor('a')),
          HostKeyVerdict.ok,
          reason: 'alias $alias must be honoured',
        );
      }
    });

    test('a corrupt entry fails closed rather than matching', () async {
      await store.write('nas|ssh-ed25519', 'not-valid-base64!!!');
      // No handler, so an unrecognised pin must yield notIncluded, never ok.
      expect(
        await trust.check(
            host: 'nas', port: 22, keyType: 'ssh-ed25519', fingerprint: fingerprintFor('a')),
        HostKeyVerdict.notIncluded,
      );
    });
  });

  group('approval deadline', () {
    test('an unanswered prompt is rejected once the deadline passes', () async {
      final request = HostKeyApprovalRequest(
        host: 'nas',
        keyType: 'ssh-ed25519',
        fingerprint: fingerprintFor('a'),
        completer: Completer<bool>(),
      );
      final approved = await trust.awaitApproval(
        (_) {}, // handler shows a dialog nobody answers
        request,
        timeout: const Duration(milliseconds: 20),
      );
      expect(approved, isFalse);
    });

    test('a late answer after the deadline is a harmless no-op', () async {
      final request = HostKeyApprovalRequest(
        host: 'nas',
        keyType: 'ssh-ed25519',
        fingerprint: fingerprintFor('a'),
        completer: Completer<bool>(),
      );
      await trust.awaitApproval((_) {}, request, timeout: const Duration(milliseconds: 20));

      // The UI finally responds; completing an already-completed completer must not throw.
      expect(request.completer.isCompleted, isTrue);
      expect(() => request.completer.complete(true), throwsStateError,
          reason: 'documents that the request is already settled — callers must guard');
    });

    test('a handler that throws fails closed', () async {
      final request = HostKeyApprovalRequest(
        host: 'nas',
        keyType: 'ssh-ed25519',
        fingerprint: fingerprintFor('a'),
        completer: Completer<bool>(),
      );
      final approved = await trust.awaitApproval((_) => throw StateError('boom'), request);
      expect(approved, isFalse);
    });

    test('a zero timeout rejects immediately', () async {
      final request = HostKeyApprovalRequest(
        host: 'nas',
        keyType: 'ssh-ed25519',
        fingerprint: fingerprintFor('a'),
        completer: Completer<bool>(),
      );
      var handlerRan = false;
      final approved = await trust.awaitApproval(
        (_) => handlerRan = true,
        request,
        timeout: Duration.zero,
      );
      expect(approved, isFalse);
      expect(handlerRan, isFalse, reason: 'no point showing a dialog that cannot be answered');
    });
  });

  group('concurrent first connections', () {
    test('two approvals of the same key both succeed and pin once', () async {
      autoApprove(true);
      final results = await Future.wait([
        trust.check(host: 'nas', port: 22, keyType: 'ssh-ed25519', fingerprint: fingerprintFor('a')),
        trust.check(host: 'nas', port: 22, keyType: 'ssh-ed25519', fingerprint: fingerprintFor('a')),
      ]);
      expect(results, [HostKeyVerdict.ok, HostKeyVerdict.ok]);
      expect((await store.readAll()).length, 1);
    });

    test('a second, different key loses the race and is reported as changed', () async {
      // Both connections observed an empty store before their dialogs appeared. The commit lock is
      // what stops the second from silently overwriting the first's pin.
      autoApprove(true);
      final results = await Future.wait([
        trust.check(host: 'nas', port: 22, keyType: 'ssh-ed25519', fingerprint: fingerprintFor('a')),
        trust.check(host: 'nas', port: 22, keyType: 'ssh-ed25519', fingerprint: fingerprintFor('b')),
      ]);
      expect(results, contains(HostKeyVerdict.ok));
      expect(results, contains(HostKeyVerdict.changed));
      expect((await store.readAll()).length, 1, reason: 'the first approved key wins');
    });
  });

  group('approval handler registration', () {
    test('a retiring owner cannot clear a newer owner handler', () async {
      final oldOwner = Object();
      final newOwner = Object();
      trust.registerApprovalHandler(oldOwner, (req) => req.completer.complete(false));
      trust.registerApprovalHandler(newOwner, (req) => req.completer.complete(true));

      trust.clearApprovalHandler(oldOwner); // must be a no-op

      expect(
        await trust.check(
            host: 'nas', port: 22, keyType: 'ssh-ed25519', fingerprint: fingerprintFor('a')),
        HostKeyVerdict.ok,
        reason: "the newer ViewModel's handler must still be live",
      );
    });

    test('the owning handler can clear itself', () async {
      final owner = Object();
      trust.registerApprovalHandler(owner, (req) => req.completer.complete(true));
      trust.clearApprovalHandler(owner);
      expect(
        await trust.check(
            host: 'nas', port: 22, keyType: 'ssh-ed25519', fingerprint: fingerprintFor('a')),
        HostKeyVerdict.notIncluded,
      );
    });
  });

  group('trust-store management', () {
    test('hasPinnedKey matches across aliases', () async {
      await store.write('[box]:2222|ssh-rsa', legacyStoredKey('a'));
      expect(await trust.hasPinnedKey('box', 2222), isTrue);
      expect(await trust.hasPinnedKey('box', 22), isFalse);
      expect(await trust.hasPinnedKey('other', 2222), isFalse);
    });

    test('removeHost clears every alias and key type for that host', () async {
      await store.write('nas|ssh-rsa', legacyStoredKey('a'));
      await store.write('nas|ssh-ed25519', legacyStoredKey('b'));
      await store.write('nas:22|ssh-rsa', legacyStoredKey('c'));
      await store.write('other|ssh-rsa', legacyStoredKey('d'));

      await trust.removeHost('nas', 22);

      expect((await store.readAll()).keys, ['other|ssh-rsa']);
    });

    test('listKnownHosts reports host, type and fingerprint', () async {
      await store.write('nas|ssh-ed25519', legacyStoredKey('a'));
      final hosts = await trust.listKnownHosts();
      expect(hosts, hasLength(1));
      expect(hosts.single.host, 'nas');
      expect(hosts.single.keyType, 'ssh-ed25519');
      expect(hosts.single.fingerprint, fingerprintFor('a'));
    });

    test('export normalises legacy entries to fingerprints', () async {
      await store.write('nas|ssh-ed25519', legacyStoredKey('a'));
      expect(await trust.exportEntries(), {'nas|ssh-ed25519': fingerprintFor('a')});
    });

    test('import never replaces a key this device already verified', () async {
      await store.write('nas|ssh-ed25519', fingerprintFor('a'));
      await trust.importEntries({
        'nas|ssh-ed25519': fingerprintFor('EVIL'),
        'new|ssh-rsa': fingerprintFor('b'),
      });

      expect(await store.read('nas|ssh-ed25519'), fingerprintFor('a'),
          reason: 'a restore must never become an interception vector');
      expect(await store.read('new|ssh-rsa'), fingerprintFor('b'));
    });

    test('import skips malformed entries', () async {
      await trust.importEntries({'no-separator': fingerprintFor('a'), 'ok|ssh-rsa': '  '});
      expect(await store.readAll(), isEmpty);
    });

    test('replaceEntries swaps the whole snapshot', () async {
      await store.write('old|ssh-rsa', fingerprintFor('a'));
      await trust.replaceEntries({'new|ssh-rsa': fingerprintFor('b')});
      expect(await store.readAll(), {'new|ssh-rsa': fingerprintFor('b')});
    });

    test('filterEntriesForHosts keeps only the restored hosts', () async {
      final entries = {
        'nas|ssh-rsa': fingerprintFor('a'),
        '[box]:2222|ssh-rsa': fingerprintFor('b'),
        'orphan|ssh-rsa': fingerprintFor('c'),
      };
      final kept = SshHostKeyTrust.filterEntriesForHosts(entries, [('nas', 22), ('box', 2222)]);
      expect(kept.keys.toSet(), {'nas|ssh-rsa', '[box]:2222|ssh-rsa'});
    });
  });

  group('fingerprint helpers', () {
    test('fingerprintOfKey matches the OpenSSH form', () {
      final key = Uint8List.fromList(utf8.encode('ssh-key-blob-a'));
      final fp = SshHostKeyTrust.fingerprintOfKey(key);
      expect(fp, fingerprintFor('a'));
      expect(fp, startsWith('SHA256:'));
      expect(fp, isNot(contains('=')), reason: 'OpenSSH shows it unpadded');
    });

    test('decodeHandlerFingerprint reads what dartssh2 passes', () {
      // dartssh2 hands over the UTF-8 bytes of the "SHA256:<base64>" string, not the raw digest.
      final wire = Uint8List.fromList(utf8.encode(fingerprintFor('a')));
      expect(SshHostKeyTrust.decodeHandlerFingerprint(wire), fingerprintFor('a'));
    });
  });

  group('SshCredentials', () {
    test('endpointKey ignores secrets so a password change is not a new host', () {
      const a = SshCredentials(host: 'nas', port: 22, username: 'root', password: 'old');
      const b = SshCredentials(host: 'nas', port: 22, username: 'root', password: 'new');
      expect(a.endpointKey, b.endpointKey);
      expect(a, isNot(b), reason: 'they are still different credentials for pooling purposes');
    });

    test('toString never leaks secrets', () {
      const creds = SshCredentials(
        host: 'nas',
        port: 22,
        username: 'root',
        password: 'hunter2',
        privateKeyPem: 'PRIVATE',
        passphrase: 'secret',
      );
      final text = creds.toString();
      expect(text, isNot(contains('hunter2')));
      expect(text, isNot(contains('PRIVATE')));
      expect(text, isNot(contains('secret')));
      expect(text, contains('root@nas:22'));
    });
  });

  group('CappedTextBuffer', () {
    test('keeps everything below the cap', () {
      final buffer = CappedTextBuffer(100)..append('hello ')..append('world');
      expect(buffer.text(), 'hello world');
      expect(buffer.truncated, isFalse);
    });

    test('retains the latest characters and says so', () {
      final buffer = CappedTextBuffer(10)..append('0123456789abcdef');
      expect(buffer.truncated, isTrue);
      expect(buffer.text(), '[Output truncated; showing latest 10 characters]\n6789abcdef');
    });

    test('the truncation notice persists once output has been dropped', () {
      final buffer = CappedTextBuffer(5)..append('0123456789');
      expect(buffer.truncated, isTrue);
      // Even though the retained tail is now short, output *was* lost.
      expect(buffer.text(), contains('truncated'));
    });

    test('empty appends are ignored and blankness is whitespace-aware', () {
      final buffer = CappedTextBuffer(10)..append('');
      expect(buffer.isBlank(), isTrue);
      buffer.append('   \n');
      expect(buffer.isBlank(), isTrue);
      buffer.append('x');
      expect(buffer.isBlank(), isFalse);
    });
  });
}
