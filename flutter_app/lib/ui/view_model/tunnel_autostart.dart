import '../../data/app_repository.dart';
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
  TunnelAutoStarter(this._repository, this._tunnels);

  final AppRepository _repository;
  final SshTunnelManager? _tunnels;

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
