import 'package:flutter_test/flutter_test.dart';
import 'package:omniterm/data/app_database.dart';
import 'package:omniterm/ui/screens/servers/server_form_state.dart';

/// The add/edit form carries two security controls, and both are tested here directly rather than
/// through the widget: stored secrets must never reach the form, and an untested configuration must
/// not be saveable.
void main() {
  Server saved({
    int id = 1,
    String name = 'nas',
    String host = '10.0.0.2',
    String? authPassword = 'stored-secret',
    String sudoPassword = 'stored-sudo',
    String proxyPassword = 'stored-proxy',
    String proxyType = 'none',
    String? group = 'prod',
  }) =>
      Server(
        id: id,
        name: name,
        host: host,
        port: 2222,
        username: 'root',
        groupName: group,
        serverColor: 'Purple',
        authType: 'password',
        authPassword: authPassword,
        sudoPassword: sudoPassword,
        notes: 'a note',
        keepAlive: 45,
        sshCompression: true,
        persistentSession: true,
        proxyCommand: '',
        proxyType: proxyType,
        proxyHost: proxyType == 'none' ? '' : 'bastion',
        proxyPort: proxyType == 'none' ? 0 : 2200,
        proxyUser: 'jump',
        proxyPassword: proxyPassword,
        agentForwarding: true,
        healthScore: 80,
        lastLatency: 12,
        status: 'online',
        authStatus: 'ok',
      );

  group('stored secrets never reach the form', () {
    test('an edit starts with blank secret fields', () {
      final form = ServerFormState(mode: ServerFormMode.edit, source: saved());
      // Rendering a saved password into a text field exposes it to shoulder-surfing, screenshots
      // and accessibility readers.
      expect(form.password, isEmpty);
      expect(form.sudoPassword, isEmpty);
      expect(form.proxyPassword, isEmpty);
    });

    test('but the form knows a secret exists, so the UI can say so', () {
      final form = ServerFormState(mode: ServerFormMode.edit, source: saved());
      expect(form.hasStoredPassword, isTrue);
      expect(form.hasStoredSudoPassword, isTrue);
      expect(form.hasStoredProxyPassword, isTrue);
    });

    test('an empty field keeps the stored value', () {
      final form = ServerFormState(mode: ServerFormMode.edit, source: saved());
      expect(form.effectivePassword, 'stored-secret');
      expect(form.toServer().authPassword, 'stored-secret',
          reason: 'saving without touching the field must not wipe the password');
    });

    test('typed text replaces the stored value', () {
      final form = ServerFormState(mode: ServerFormMode.edit, source: saved())
        ..password = 'new-secret';
      expect(form.effectivePassword, 'new-secret');
    });

    test('only the forget flag clears a secret', () {
      final form = ServerFormState(mode: ServerFormMode.edit, source: saved())
        ..forgetPassword = true;
      expect(form.effectivePassword, isEmpty);
      expect(form.toServer().authPassword, isEmpty);
    });

    test('typed text wins over the forget flag', () {
      // Typing a replacement and also ticking forget is a contradiction; the typed value is the
      // more recent, more explicit intent.
      final form = ServerFormState(mode: ServerFormMode.edit, source: saved())
        ..password = 'typed'
        ..forgetPassword = true;
      expect(form.effectivePassword, 'typed');
    });

    test('each secret is forgotten independently', () {
      final form = ServerFormState(mode: ServerFormMode.edit, source: saved())
        ..forgetSudoPassword = true;
      expect(form.effectiveSudoPassword, isEmpty);
      expect(form.effectivePassword, 'stored-secret');
      expect(form.effectiveProxyPassword, 'stored-proxy');
    });
  });

  group('the connection-test gate', () {
    test('a new host cannot be saved until it has been tested', () {
      // This is what stops the first-connect host-key approval from being skipped.
      final form = ServerFormState(mode: ServerFormMode.add)
        ..name = 'new'
        ..host = '10.0.0.9'
        ..username = 'root';
      expect(form.validationError, isNull);
      expect(form.requiresConnectionTest, isTrue);
      expect(form.canSave, isFalse);

      form.markConnectionTested();
      expect(form.canSave, isTrue);
    });

    test('an existing host counts as already tested', () {
      final form = ServerFormState(mode: ServerFormMode.edit, source: saved());
      expect(form.requiresConnectionTest, isFalse);
    });

    test('a cosmetic edit does not force a retest', () {
      final form = ServerFormState(mode: ServerFormMode.edit, source: saved())
        ..name = 'renamed'
        ..group = 'other'
        ..serverColor = 'Green'
        ..notes = 'changed';
      expect(form.requiresConnectionTest, isFalse,
          reason: 'renaming a host must not demand a round trip to the server');
    });

    test('changing any connection field invalidates a previous pass', () {
      for (final mutate in <void Function(ServerFormState)>[
        (f) => f.host = 'elsewhere',
        (f) => f.port = '22',
        (f) => f.username = 'other',
        (f) => f.authType = 'key',
        (f) => f.password = 'different',
        (f) => f.selectedKeyAlias = 'laptop',
        (f) => f.selectedProfileId = 3,
        (f) => f.proxyType = 'socks5',
        (f) => f.proxyHost = 'proxy',
        (f) => f.proxyUser = 'p',
        (f) => f.proxyPassword = 'p',
        (f) => f.proxyKeyAlias = 'k',
      ]) {
        final form = ServerFormState(mode: ServerFormMode.edit, source: saved());
        expect(form.requiresConnectionTest, isFalse);
        mutate(form);
        expect(form.requiresConnectionTest, isTrue,
            reason: 'a changed connection field must re-run the host-key gate');
      }
    });

    test('forgetting a password invalidates the pass', () {
      final form = ServerFormState(mode: ServerFormMode.edit, source: saved())
        ..forgetPassword = true;
      expect(form.requiresConnectionTest, isTrue);
    });

    test('the signature cannot be forged by a value containing the separator', () {
      // A space-joined signature would let "a" + "b c" collide with "a b" + "c".
      final a = ServerFormState(mode: ServerFormMode.add)
        ..host = 'a'
        ..username = 'b c';
      final b = ServerFormState(mode: ServerFormMode.add)
        ..host = 'a b'
        ..username = 'c';
      expect(a.connectionSignature, isNot(b.connectionSignature));
    });
  });

  group('duplicate', () {
    test('seeds the source secrets — that is the point of "reuse credentials"', () {
      final form = ServerFormState(mode: ServerFormMode.duplicate, source: saved());
      expect(form.password, 'stored-secret');
      expect(form.sudoPassword, 'stored-sudo');
      expect(form.proxyPassword, 'stored-proxy');
    });

    test('names the copy and saves as a new independent host', () {
      final form = ServerFormState(mode: ServerFormMode.duplicate, source: saved());
      expect(form.name, 'nas copy');
      expect(form.toServer().id, 0, reason: 'a duplicate must not overwrite its source');
    });

    test('still faces the host-key gate', () {
      final form = ServerFormState(mode: ServerFormMode.duplicate, source: saved());
      expect(form.requiresConnectionTest, isTrue,
          reason: 'a copy shares no trust state with its source');
    });

    test('does not inherit the source health or status', () {
      final row = ServerFormState(mode: ServerFormMode.duplicate, source: saved()).toServer();
      expect(row.status, 'offline');
      expect(row.authStatus, 'unknown');
      expect(row.healthScore, 100);
    });
  });

  group('validation', () {
    ServerFormState valid() => ServerFormState(mode: ServerFormMode.add)
      ..name = 'n'
      ..host = 'h'
      ..username = 'u';

    test('required fields are reported one at a time', () {
      expect(ServerFormState(mode: ServerFormMode.add).validationError, 'Name is required');
      expect((valid()..name = '  ').validationError, 'Name is required');
      expect((valid()..host = '').validationError, 'Host is required');
      expect((valid()..username = '').validationError, 'Username is required');
    });

    test('port must be in range', () {
      // Through the shared `portError`, so the rule is stated once for every port in the app.
      expect((valid()..port = '0').validationError, 'Port: Must be 1-65535');
      expect((valid()..port = '65536').validationError, 'Port: Must be 1-65535');
      expect((valid()..port = 'abc').validationError, 'Port: Must be a whole number');
      expect((valid()..port = '').validationError, 'Port: Required');
      expect((valid()..port = '22').validationError, isNull);
    });

    test('proxy fields are only required when a proxy is configured', () {
      expect(valid().validationError, isNull);
      final withProxy = valid()..proxyType = 'socks5';
      expect(withProxy.validationError, 'Proxy host is required');
      withProxy.proxyHost = 'p';
      expect(withProxy.validationError, 'Proxy port: Required');
      withProxy.proxyPort = '99999';
      expect(withProxy.validationError, 'Proxy port: Must be 1-65535');
      withProxy.proxyPort = '1080';
      expect(withProxy.validationError, isNull);
    });
  });

  group('toServer', () {
    test('an edit keeps the row id so it updates in place', () {
      final row = ServerFormState(mode: ServerFormMode.edit, source: saved(id: 7)).toServer();
      expect(row.id, 7);
    });

    test('a jump key is kept only for an ssh proxy', () {
      final ssh = ServerFormState(mode: ServerFormMode.add)
        ..proxyType = 'ssh'
        ..proxyKeyAlias = 'bastion-key';
      expect(ssh.toServer().proxyKeyAlias, 'bastion-key');

      final http = ServerFormState(mode: ServerFormMode.add)
        ..proxyType = 'http'
        ..proxyKeyAlias = 'bastion-key';
      expect(http.toServer().proxyKeyAlias, isNull,
          reason: 'a key means nothing to an HTTP proxy');
    });

    test('fields are trimmed', () {
      final row = (ServerFormState(mode: ServerFormMode.add)
            ..name = '  nas  '
            ..host = '  10.0.0.2 '
            ..username = ' root ')
          .toServer();
      expect(row.name, 'nas');
      expect(row.host, '10.0.0.2');
      expect(row.username, 'root');
    });

    test('an empty key alias becomes null rather than an empty string', () {
      expect(ServerFormState(mode: ServerFormMode.add).toServer().authKeyAlias, isNull);
    });
  });

  test('group options offer Default plus every label in use, without duplicates', () {
    final options = ServerFormState.groupOptions([
      saved(id: 1, group: 'prod'),
      saved(id: 2, group: 'prod'),
      saved(id: 3, group: 'home'),
      saved(id: 4, group: null),
    ]);
    expect(options, ['Default', 'prod', 'home'],
        reason: 'offering existing labels stops a typo silently forking a near-duplicate group');
  });
}
