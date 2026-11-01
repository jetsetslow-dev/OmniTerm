import '../../data/app_repository.dart';
import '../../data/ssh/ssh_host_key_trust.dart';
import '../../data/ssh/ssh_tunnel_manager.dart';
import '../../domain/server_credentials.dart';

/// Brings up the tunnels marked "start when OmniTerm opens", once per app lifetime.
///
/// Ported from the auto-start block in `AppViewModel`'s init. Three properties are deliberate and
/// each one is a decision, not an implementation detail:
///
/// - **Once.** The saved-tunnel list is a stream that fires on every edit; starting from the stream
///   would re-dial a tunnel every time the user renamed an unrelated one.
/// - **App-lifetime scoped.** Nothing here persists a tunnel across a restart, and the provider that
///   owns the manager tears every forward down on dispose. A port that outlived the app would be a
///   listener nobody can see or stop.
/// - **Failures are silent here.** A tunnel that cannot start at launch — a host that is asleep, a
///   port already taken — must not produce an error banner over whatever screen the user opened to.
///   The Tunnels tab shows the switch in its real state, and trying it there reports why.
///
/// Constructed eagerly (`lazy: false`) for the same reason `HostStatusProbe` is: nothing in the
/// widget tree reads it, so with the default it would never be built at all (§15.8). Being eager is
/// also why it reads hosts from the repository rather than from `AppState` — at that moment the
/// in-memory list is still empty.
class TunnelAutoStarter {
  TunnelAutoStarter(this._repository, this._tunnels, {SshHostKeyTrust? trust})
    // ignore: prefer_initializing_formals — a private field cannot be a named initializing formal.
    : _trust = trust;

  final AppRepository _repository;
  final SshTunnelManager? _tunnels;

  /// Used to skip hosts whose key has never been approved. Nullable so a build without the trust
  /// store still starts tunnels rather than refusing everything.
  final SshHostKeyTrust? _trust;

  bool _ran = false;

  /// Starts every tunnel whose row asks for it. Safe to call more than once; only the first runs.
  Future<void> start() async {
    if (_ran) return;
    _ran = true;
    final manager = _tunnels;
    if (manager == null) return;

    final rows = (await _repository.getAllPortForwards()).where((pf) => pf.autoStart).toList();
    if (rows.isEmpty) return;

    final keys = await _repository.getAllKeys();
    final profiles = await _repository.getAllProfiles();
    // Read from the repository, **not** from `AppState.servers`. This runs eagerly at startup,
    // which is before `AppState.start()` has finished loading hosts — so the in-memory list can
    // still be empty here and every tunnel would be skipped with nothing reporting why. The
    // repository has no such ordering to get wrong.
    final servers = await _repository.getAllServers();

    for (final pf in rows) {
      final server = servers.where((s) => s.id == pf.serverId).firstOrNull;
      if (server == null) continue;

      // A host whose key has never been approved is skipped, not dialled.
      //
      // Observed on a device: dialling one throws the "Trust this server?" prompt over whatever the
      // user opened the app to do, and then fails closed 120 seconds later if they do not answer.
      // A trust decision asked out of context, at launch, is the one most likely to be tapped
      // through — and the honest place to make it is the first deliberate connection to that host.
      if (_trust != null && !await _trust.hasPinnedKey(server.host, server.port)) continue;

      try {
        await manager.start(
          id: pf.id,
          creds: resolveCredentials(server, keys: keys, profiles: profiles),
          kind: pf.kind,
          bindHost: pf.bindHost,
          bindPort: pf.bindPort,
          destHost: pf.destHost,
          destPort: pf.destPort,
        );
      } catch (_) {
        // Deliberately swallowed — see the note above. The tunnel's own card is where a failure
        // belongs, and it will show the switch off.
      }
    }
  }
}
