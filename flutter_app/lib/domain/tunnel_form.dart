/// Describing and validating a saved SSH port forward.
///
/// Ported from `tunnelSummary` and the tunnel editor's gate in `ui/ToolsScreen.kt`. The validation
/// half exists because of the Kotlin's own PR #67: screens parsed typed ports with
/// `toIntOrNull() ?: default`, so an empty field saved a port nobody chose. A tunnel is the worst
/// place for that — the value silently becomes 0, the bind succeeds on an arbitrary port, and the
/// forward appears to be running somewhere the user cannot find.
library;

import 'input_validation.dart';

/// The three forwarding modes, in OpenSSH's own vocabulary.
///
/// The flag names are deliberate: anyone who has typed `ssh -L` knows exactly what this row does,
/// and a home-grown wording would make them work it out again.
const tunnelKinds = <String, String>{
  'local': '-L  local → remote',
  'remote': '-R  remote → local',
  'dynamic': '-D  SOCKS5 proxy',
};

/// True when [kind] carries traffic to a named destination.
///
/// A dynamic forward has no fixed destination — that is the point of SOCKS — so asking for one
/// would be asking a question with no answer.
bool tunnelHasDestination(String kind) => kind != 'dynamic';

/// One line describing what the forward does, in `ssh` flag terms.
///
/// [maskHost] is applied to the *destination* only. The bind side is on this device and is
/// already visible to whoever is holding it; the destination is a machine on the user's network,
/// which is what "Hide addresses" is for.
String tunnelSummary({
  required String kind,
  required String bindHost,
  required int bindPort,
  required String destHost,
  required int destPort,
  String Function(String)? maskHost,
}) {
  final dest = maskHost?.call(destHost) ?? destHost;
  return switch (kind) {
    'remote' => '-R $bindHost:$bindPort → $dest:$destPort',
    'dynamic' => '-D $bindHost:$bindPort (SOCKS5)',
    _ => '-L $bindHost:$bindPort → $dest:$destPort',
  };
}

/// The first reason this tunnel cannot be saved, or null when it can.
///
/// Every field is checked against the shared validators rather than a local copy of the same range,
/// so "what is a valid port" is stated once for the whole app.
String? tunnelFormError({
  required String name,
  required String kind,
  required int? serverId,
  required String bindHost,
  required String bindPort,
  required String destHost,
  required String destPort,
}) {
  if (name.trim().isEmpty) return 'Name is required.';
  if (serverId == null) return 'Choose the host this tunnel runs over.';
  if (!tunnelKinds.containsKey(kind)) return 'Choose a forwarding mode.';

  if (bindHost.trim().isEmpty) return 'Bind address is required.';
  final bindFailure = portError(bindPort);
  if (bindFailure != null) return 'Bind port: $bindFailure';

  if (tunnelHasDestination(kind)) {
    if (destHost.trim().isEmpty) return 'Destination host is required.';
    final destFailure = portError(destPort);
    if (destFailure != null) return 'Destination port: $destFailure';
  }
  return null;
}
