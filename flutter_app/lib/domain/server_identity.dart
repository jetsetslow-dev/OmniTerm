import '../data/app_database.dart';

/// Display labels, profile ids and stored secrets do not identify a connection.
/// SSH usernames stay case-sensitive; profile-backed logins use their actual user/auth method.
(String, int, String, String)? serverIdentity(Server server, List<CredentialProfile> profiles) {
  var username = server.username;
  var authType = server.authType;
  if (authType == 'profile') {
    final profile = profiles.where((p) => p.id == server.authProfileId).firstOrNull;
    if (profile == null) return null;
    username = profile.username;
    authType = profile.authType;
  }
  return (server.host.trim().toLowerCase(), server.port, username, authType);
}

class DuplicateServerException implements Exception {
  const DuplicateServerException(this.existingName);
  final String existingName;

  @override
  String toString() =>
      'The same host, port, SSH user and authentication method already exist '
      'as "$existingName". Existing server unchanged.';
}

/// Only newly colliding pairs block an edit. Existing duplicates must not prevent a user from
/// rotating a password or renaming a profile, neither of which changes the effective login.
List<(String, String)> profileServerConflicts(
  List<Server> servers,
  List<CredentialProfile> profiles,
  CredentialProfile candidate,
) {
  final after = [...profiles.where((profile) => profile.id != candidate.id), candidate];
  final beforeIdentities = [for (final server in servers) serverIdentity(server, profiles)];
  final afterIdentities = [for (final server in servers) serverIdentity(server, after)];
  final conflicts = <(String, String)>[];
  for (var i = 0; i < servers.length; i++) {
    if (afterIdentities[i] == null) continue;
    for (var j = i + 1; j < servers.length; j++) {
      if (afterIdentities[i] != afterIdentities[j]) continue;
      if (beforeIdentities[i] != null && beforeIdentities[i] == beforeIdentities[j]) continue;
      conflicts.add((servers[i].name, servers[j].name));
    }
  }
  return conflicts;
}

class ProfileServerConflictException implements Exception {
  const ProfileServerConflictException(this.conflicts);
  final List<(String, String)> conflicts;

  @override
  String toString() =>
      'Profile not saved. These servers would have the same host, port, SSH user '
      'and authentication method:\n${conflicts.map((pair) => '"${pair.$1}" and "${pair.$2}"').join('\n')}\n'
      'Profile and servers unchanged.';
}
