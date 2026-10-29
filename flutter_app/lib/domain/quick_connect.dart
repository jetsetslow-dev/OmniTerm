import '../data/app_database.dart';

/// What the Quick connect dialog submits: the parameters of Kotlin's `AppViewModel.quickConnect`.
class QuickConnectInput {
  const QuickConnectInput({
    required this.host,
    required this.port,
    required this.username,
    required this.authType,
    this.password,
    this.keyAlias,
    this.profileId,
    this.proxyType = 'none',
    this.proxyHost = '',
    this.proxyPort = 0,
    this.proxyUser = '',
    this.proxyPassword = '',
    this.proxyKeyAlias,
  });

  final String host;
  final int port;
  final String username;
  final String authType;
  final String? password;
  final String? keyAlias;
  final int? profileId;
  final String proxyType;
  final String proxyHost;
  final int proxyPort;
  final String proxyUser;
  final String proxyPassword;
  final String? proxyKeyAlias;
}

/// Why [input] cannot be connected, in Kotlin's words and order, or null when it can.
///
/// The dialog checks its port fields first so the message names the offending field; this repeats
/// the range checks because it is the funnel every ad-hoc connection passes through.
String? quickConnectError(QuickConnectInput input, {required bool connecting}) {
  if (input.host.trim().isEmpty) return 'Host is required.';
  if (input.port < 1 || input.port > 65535) return 'SSH port must be 1-65535.';
  if (input.authType != 'profile' && input.username.trim().isEmpty) {
    return 'SSH username is required.';
  }
  if (input.authType == 'profile' && input.profileId == null) return 'Select a credential profile.';
  if (input.authType == 'key' && (input.keyAlias ?? '').trim().isEmpty) return 'Select a key.';
  if (input.proxyType != 'none') {
    if (input.proxyHost.trim().isEmpty) {
      return 'Proxy host is required for a ${input.proxyType} proxy.';
    }
    if (input.proxyPort < 1 || input.proxyPort > 65535) return 'Proxy port must be 1-65535.';
  }
  if (connecting) return 'A connection is already in progress.';
  return null;
}

/// The in-memory row for an accepted [input]. It is never written to the database.
///
/// [id] is negative, as in Kotlin, so it can never match a saved host or the `0` that alert rules
/// use for "all hosts". The session is never persistent: nothing is left on the server to resume.
Server quickConnectServer(QuickConnectInput input, {required int id}) {
  final host = input.host.trim();
  final name = '${input.username}@$host';
  return Server(
    id: id,
    name: name.startsWith('@') ? name.substring(1) : name,
    host: host,
    port: input.port,
    username: input.username,
    serverColor: 'Default',
    authType: input.authType,
    authPassword: input.password,
    authKeyAlias: input.keyAlias,
    authProfileId: input.profileId,
    sudoPassword: '',
    notes: '',
    keepAlive: 30,
    sshCompression: false,
    persistentSession: false,
    proxyCommand: '',
    proxyType: input.proxyType,
    proxyHost: input.proxyHost.trim(),
    proxyPort: input.proxyPort,
    proxyUser: input.proxyUser,
    proxyPassword: input.proxyPassword,
    proxyKeyAlias: (input.proxyKeyAlias ?? '').trim().isNotEmpty && input.proxyType == 'ssh'
        ? input.proxyKeyAlias
        : null,
    agentForwarding: false,
    healthScore: -1,
    lastLatency: 0,
    status: 'offline',
    authStatus: 'unknown',
  );
}
