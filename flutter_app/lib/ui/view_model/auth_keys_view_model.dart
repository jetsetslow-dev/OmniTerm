import 'dart:async';

import 'package:drift/drift.dart' show Value;
import 'package:flutter/foundation.dart';

import '../../data/app_database.dart';
import '../../data/remote_models.dart';
import '../../data/ssh/ssh_host_key_trust.dart';
import '../../domain/ssh_key_import.dart';
import '../../domain/ssh_keygen.dart';
import 'app_state.dart';

/// Produces a keypair for [AuthKeysViewModel.generateKey].
typedef SshKeyGenerator =
    Future<GeneratedSshKey> Function({
      required String alias,
      required String keyType,
      required Set<String> existingAliases,
    });

/// Generates on a background isolate.
///
/// A 4096-bit modulus takes seconds of solid CPU; doing it inline would freeze the frame loop, which
/// reads to the user as the app having hung.
Future<GeneratedSshKey> _generateOnIsolate({
  required String alias,
  required String keyType,
  required Set<String> existingAliases,
}) => compute(_generateInIsolate, <String, Object>{
  'alias': alias,
  'keyType': keyType,
  'existingAliases': existingAliases.toList(),
});

/// Runs on the spawned isolate, so it must be a top-level function over plain data.
GeneratedSshKey _generateInIsolate(Map<String, Object> request) => generateSshKeyPair(
  alias: request['alias']! as String,
  keyType: request['keyType']! as String,
  existingAliases: (request['existingAliases']! as List<dynamic>).cast<String>().toSet(),
);

/// The Auth Keys tool's state and actions, split out of `AuthKeysToolView` in `ui/ToolsScreen.kt`.
///
/// Owns three related stores: SSH private keys, credential profiles, and the trusted host-key
/// records. They sit together because they are the app's whole answer to "who am I, and who am I
/// talking to".
class AuthKeysViewModel extends ChangeNotifier {
  AuthKeysViewModel(this._app, {this.hostKeyTrust, SshKeyGenerator? keyGenerator})
    : _keyGenerator = keyGenerator ?? _generateOnIsolate;

  final AppState _app;

  /// How a keypair is produced. Overridden in tests so they can generate a throwaway modulus in
  /// milliseconds instead of waiting seconds for a production-strength one.
  final SshKeyGenerator _keyGenerator;

  /// Null in tests and in any build without a trust store wired; the trusted-hosts section then
  /// reports that rather than showing an empty list, which would read as "nothing is trusted".
  final SshHostKeyTrust? hostKeyTrust;

  bool get canManageTrust => hostKeyTrust != null;

  bool _disposed = false;

  void _safeNotify() {
    if (!_disposed) notifyListeners();
  }

  // ── stored credentials ──────────────────────────────────────────────────────

  List<SshKey> _keys = const [];
  List<CredentialProfile> _profiles = const [];
  List<KnownHost> _knownHosts = const [];

  List<SshKey> get keys => List.unmodifiable(_keys);
  List<CredentialProfile> get profiles => List.unmodifiable(_profiles);

  /// Hosts whose key has been pinned, newest trust first is not meaningful here so they stay in
  /// store order.
  List<KnownHost> get knownHosts => List.unmodifiable(_knownHosts);

  bool _loading = false;
  String? _error;
  String? _status;

  bool get loading => _loading;

  /// A failure from the last action, shown until dismissed or superseded.
  String? get error => _error;

  /// A confirmation of the last action.
  String? get status => _status;

  void dismissMessages() {
    _error = null;
    _status = null;
    notifyListeners();
  }

  StreamSubscription<List<SshKey>>? _keysSub;
  StreamSubscription<List<CredentialProfile>>? _profilesSub;

  /// Subscribes to the credential stores and reads the trust store once.
  Future<void> start() async {
    _loading = true;
    _safeNotify();

    _keysSub ??= _app.repository.keysStream.listen((list) {
      _keys = list;
      _safeNotify();
    });
    _profilesSub ??= _app.repository.profilesStream.listen((list) {
      _profiles = list;
      _safeNotify();
    });

    await refreshKnownHosts();
    _loading = false;
    _safeNotify();
  }

  /// Re-reads the pinned host keys.
  ///
  /// Not a stream: the trust store is written by the connection path, which is not observable, so
  /// this is called when the screen opens and after a revoke.
  Future<void> refreshKnownHosts() async {
    final trust = hostKeyTrust;
    if (trust == null) return;
    try {
      _knownHosts = await trust.listKnownHosts();
    } catch (e) {
      _error = e.toString();
    }
    _safeNotify();
  }

  // ── ssh keys ────────────────────────────────────────────────────────────────

  /// Imports a key from pasted text.
  ///
  /// Returns null on success, otherwise the reason — which is shown verbatim, because the parser's
  /// messages are the useful part ("that looks like a public key" beats "invalid key").
  Future<String?> importKey({
    required String alias,
    required String privateKey,
    String publicKey = '',
    String keyType = '',
  }) async {
    try {
      final prepared = prepareKeyImport(
        alias: alias,
        privateKey: privateKey,
        publicKey: publicKey,
        keyType: keyType,
        existingAliases: _keys.map((k) => k.alias).toSet(),
      );
      await _app.repository.insertKey(
        SshKey(
          id: 0,
          alias: prepared.alias,
          keyType: prepared.keyType,
          privateKey: prepared.privateKey,
          publicKey: prepared.publicKey,
          fingerprint: prepared.fingerprint,
        ),
      );
      _status = "Imported ${prepared.keyType} key '${prepared.alias}'.";
      _error = null;
      _safeNotify();
      return null;
    } on KeyImportException catch (e) {
      _error = e.message;
      _safeNotify();
      return e.message;
    } catch (e) {
      final message = 'Key import failed: $e';
      _error = message;
      _safeNotify();
      return message;
    }
  }

  /// True while a keypair is being generated.
  ///
  /// Kotlin guards on the same flag: RSA generation runs for seconds, and without it a second tap
  /// would start a competing generation whose result overwrites the first.
  bool get keygenRunning => _keygenRunning;
  bool _keygenRunning = false;

  /// Generates a keypair, stores it, and returns it for display.
  ///
  /// The caller is handed the material because this is the *only* moment the private key can be
  /// shown: it is stored encrypted and never read back out to the UI afterwards. Returns null when
  /// generation was refused, with the reason in [error].
  Future<GeneratedSshKey?> generateKey({
    required String alias,
    String keyType = 'RSA',
  }) async {
    if (_keygenRunning) return null;
    _keygenRunning = true;
    _error = null;
    _safeNotify();
    try {
      final trimmed = alias.trim();
      final generated = await _keyGenerator(
        alias: trimmed,
        keyType: keyType,
        existingAliases: _keys.map((k) => k.alias).toSet(),
      );
      await _app.repository.insertKey(
        SshKey(
          id: 0,
          alias: trimmed,
          keyType: generated.keyType,
          privateKey: generated.privateKey,
          publicKey: generated.publicKey,
          fingerprint: generated.fingerprint,
        ),
      );
      _status = "Generated ${generated.keyType} key '$trimmed'.";
      return generated;
    } on KeyGenerationException catch (e) {
      _error = e.message;
      return null;
    } catch (e) {
      _error = 'Key generation failed: $e';
      return null;
    } finally {
      // Must clear on failure too, or the button stays disabled for the rest of the session.
      _keygenRunning = false;
      _safeNotify();
    }
  }

  /// Renames a stored key.
  ///
  /// The alias is what a host records to name its key, so the hosts referencing it are updated in
  /// the same breath — otherwise they would point at an alias that no longer resolves and would
  /// fall back to failing at connect time.
  Future<String?> renameKey(SshKey key, String newAlias) async {
    final trimmed = newAlias.trim();
    if (trimmed.isEmpty) return 'Key alias is required.';
    if (trimmed == key.alias) return null;
    if (_keys.any((k) => k.alias == trimmed)) return 'Key alias already exists.';

    await _app.repository.insertKey(key.copyWith(alias: trimmed));
    for (final server in _app.servers.where((s) => s.authKeyAlias == key.alias)) {
      await _app.repository.updateServer(server.copyWith(authKeyAlias: Value(trimmed)));
    }
    for (final server in _app.servers.where((s) => s.proxyKeyAlias == key.alias)) {
      await _app.repository.updateServer(server.copyWith(proxyKeyAlias: Value(trimmed)));
    }
    _status = "Renamed key to '$trimmed'.";
    _safeNotify();
    return null;
  }

  /// The hosts that would stop authenticating if [key] were deleted.
  ///
  /// Shown in the confirmation, because "delete this key" gives no sense of the blast radius and the
  /// private material cannot be recovered afterwards.
  List<Server> hostsUsingKey(SshKey key) => _app.servers
      .where((s) => s.authKeyAlias == key.alias || s.proxyKeyAlias == key.alias)
      .toList();

  Future<void> deleteKey(SshKey key) async {
    await _app.repository.deleteKey(key);
    _status = "Deleted key '${key.alias}'.";
    _safeNotify();
  }

  // ── credential profiles ─────────────────────────────────────────────────────

  /// Saves a profile, inserting when [existing] is null.
  Future<String?> saveProfile({
    CredentialProfile? existing,
    required String profileName,
    required String username,
    required String authType,
    String password = '',
    String keyAlias = '',
    String groupName = 'General',
  }) async {
    final name = profileName.trim();
    if (name.isEmpty) return 'Profile name is required.';
    if (username.trim().isEmpty) return 'Username is required.';
    if (_profiles.any((p) => p.profileName == name && p.id != existing?.id)) {
      return 'A profile named "$name" already exists.';
    }
    if (authType == 'key' && keyAlias.trim().isEmpty) {
      return 'Pick a key for a key-authenticated profile.';
    }

    await _app.repository.insertProfile(
      CredentialProfile(
        id: existing?.id ?? 0,
        profileName: name,
        username: username.trim(),
        authType: authType,
        // A key profile must not also carry a password: a server that rejects the key could
        // otherwise harvest it. Same rule the credential resolver enforces at connect time.
        password: authType == 'key' ? null : (password.isEmpty ? existing?.password : password),
        keyAlias: authType == 'key' ? keyAlias.trim() : null,
        groupName: groupName,
      ),
    );
    _status = "Saved profile '$name'.";
    _safeNotify();
    return null;
  }

  /// The hosts that would stop authenticating if [profile] were deleted.
  List<Server> hostsUsingProfile(CredentialProfile profile) =>
      _app.servers.where((s) => s.authProfileId == profile.id).toList();

  Future<void> deleteProfile(CredentialProfile profile) async {
    await _app.repository.deleteProfile(profile);
    _status = "Deleted profile '${profile.profileName}'.";
    _safeNotify();
  }

  // ── trusted host keys ───────────────────────────────────────────────────────

  /// Forgets a pinned host key.
  ///
  /// The next connection to that host will present its key for approval again. That is the *point*:
  /// revoking is how a user recovers from a legitimate key change (a rebuilt server) without editing
  /// a trust store by hand — and it is also the only honest response to a key that changed
  /// unexpectedly, once they have verified the new one out of band.
  Future<void> revokeKnownHost(KnownHost host) async {
    final trust = hostKeyTrust;
    if (trust == null) return;
    final (hostName, port) = splitHostPort(host.host);
    try {
      await trust.removeHost(hostName, port);
      _status = 'Forgot the pinned key for ${host.host}.';
    } catch (e) {
      _error = e.toString();
    }
    await refreshKnownHosts();
  }

  /// Splits the alias a pinned key is stored under back into host and port.
  ///
  /// The store uses JSch's convention: a bare `host` on port 22, `[host]:port` otherwise. The
  /// brackets exist precisely so an IPv6 address — which is full of colons — is unambiguous, so they
  /// are what this parses first. A bare address with several colons is IPv6 on the default port, not
  /// a host with a port; reading its last group as one would revoke nothing.
  static (String, int) splitHostPort(String label) {
    if (label.startsWith('[')) {
      final close = label.indexOf(']');
      if (close > 0) {
        final host = label.substring(1, close);
        final rest = label.substring(close + 1);
        final port = rest.startsWith(':') ? int.tryParse(rest.substring(1)) : null;
        return (host, port ?? 22);
      }
    }
    final colon = label.lastIndexOf(':');
    // More than one colon and no brackets: a bare IPv6 address.
    if (colon <= 0 || label.indexOf(':') != colon) return (label, 22);
    final port = int.tryParse(label.substring(colon + 1));
    if (port == null) return (label, 22);
    return (label.substring(0, colon), port);
  }

  @override
  void dispose() {
    _disposed = true;
    _keysSub?.cancel();
    _profilesSub?.cancel();
    super.dispose();
  }
}
