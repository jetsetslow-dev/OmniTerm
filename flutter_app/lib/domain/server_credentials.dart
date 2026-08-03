import '../data/app_database.dart';
import '../data/ssh/ssh_transport.dart';

/// Raised when a host's saved configuration cannot be turned into a usable credential set.
///
/// This is deliberately an error rather than a silent fallback: if a host says "authenticate with
/// key `laptop`" and that key is gone, quietly trying the password instead would send a credential
/// somewhere the user never agreed to send it, and would mask the real fault (a deleted key).
class CredentialResolutionException implements Exception {
  const CredentialResolutionException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Turns a stored [Server] row into the [SshCredentials] the transport needs.
///
/// One resolver for the whole app. Every screen that opens a connection — the form's Test
/// Connection, the terminal, the monitor poller, SFTP, the fleet runner — goes through here, so the
/// rules about which secret is used (and which is *not*) exist in exactly one place. Duplicating
/// this per screen is how a host ends up connecting with different credentials depending on which
/// button was pressed.
///
/// [keys] and [profiles] must already be **decrypted** (as `AppRepository` returns them).
SshCredentials resolveCredentials(
  Server server, {
  List<SshKey> keys = const [],
  List<CredentialProfile> profiles = const [],
}) {
  var username = server.username;
  var authType = server.authType;
  var password = server.authPassword ?? '';
  var keyAlias = server.authKeyAlias ?? '';

  // A profile is an indirection, not a third auth mechanism: it supplies the identity, then the
  // usual password/key rules apply to what it supplied.
  if (authType == 'profile') {
    final profileId = server.authProfileId;
    if (profileId == null) {
      throw const CredentialResolutionException(
        'This host authenticates with a credential profile, but no profile is selected.',
      );
    }
    final profile = profiles.where((p) => p.id == profileId).firstOrNull;
    if (profile == null) {
      throw CredentialResolutionException(
        'Credential profile #$profileId no longer exists. Pick another in the host settings.',
      );
    }
    username = profile.username;
    authType = profile.authType;
    password = profile.password ?? '';
    keyAlias = profile.keyAlias ?? '';
  }

  String? privateKeyPem;
  if (authType == 'key') {
    if (keyAlias.isEmpty) {
      throw const CredentialResolutionException(
        'This host authenticates with a key, but no key is selected.',
      );
    }
    final key = keys.where((k) => k.alias == keyAlias).firstOrNull;
    if (key == null) {
      throw CredentialResolutionException(
        'The key "$keyAlias" is no longer saved. Import it again or switch this host to a password.',
      );
    }
    privateKeyPem = key.privateKey;
    // A key-authenticated host must not also offer its stored password: that would let a server
    // that rejects the key harvest the password instead.
    password = '';
  }

  // The jump host's key is looked up the same way, and its own passphrase is not the target's.
  String? proxyKeyPem;
  final proxyAlias = server.proxyKeyAlias ?? '';
  if (server.proxyType == 'ssh' && proxyAlias.isNotEmpty) {
    final proxyKey = keys.where((k) => k.alias == proxyAlias).firstOrNull;
    if (proxyKey == null) {
      throw CredentialResolutionException(
        'The jump-host key "$proxyAlias" is no longer saved.',
      );
    }
    proxyKeyPem = proxyKey.privateKey;
  }

  return SshCredentials(
    host: server.host,
    port: server.port,
    username: username,
    password: password.isEmpty ? null : password,
    privateKeyPem: privateKeyPem,
    proxyType: server.proxyType,
    proxyHost: server.proxyHost,
    proxyPort: server.proxyPort,
    proxyUser: server.proxyUser,
    proxyPassword: server.proxyPassword,
    proxyKeyPem: proxyKeyPem,
    keepAliveSeconds: server.keepAlive,
    compression: server.sshCompression,
    agentForwarding: server.agentForwarding,
  );
}
