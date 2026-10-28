import 'package:flutter/foundation.dart';

import '../../data/app_database.dart';
import '../../data/kotlin_strings.dart';
import '../../data/remote_commands.dart';
import '../../data/ssh/ssh_transport.dart';
import '../../data/system_specs.dart';
import '../../domain/server_credentials.dart';
import 'app_state.dart';

/// What the specs screens show for one host: the last read, and whether another is under way.
@immutable
class SystemSpecsState {
  const SystemSpecsState({this.specs, this.loading = false, this.error, this.elevated = false});

  final SystemSpecs? specs;
  final bool loading;
  final String? error;

  /// The last read used sudo, so a refresh does too.
  final bool elevated;
}

/// System specs for Monitor › Specs and the Hosts tab's ⋮ › System specs, ported from the specs
/// part of `ui/AppViewModel.kt`.
///
/// Kept per host for the session: specs change only when hardware or the OS does. Both screens read
/// the same entry, so opening one after the other does not read the host twice. Which sections and
/// devices are expanded is kept per host too, so switching hosts and back finds each sheet as it
/// was left.
class SystemSpecsViewModel extends ChangeNotifier {
  SystemSpecsViewModel(this._app, {this.transport}) {
    _app.onHostForgotten.add(_forget);
  }

  final AppState _app;
  final SshTransport? transport;

  final Map<int, SystemSpecsState> _states = {};
  final Map<int, int> _generations = {};
  final Map<int, Set<String>> _expanded = {};
  bool _disposed = false;

  SystemSpecsState? stateFor(int serverId) => _states[serverId];

  /// Reads [server]'s specs. [withSudo] also reads what needs root (memory modules, drive health)
  /// through sudo; a refresh after that keeps doing so, so the detail does not vanish again.
  ///
  /// The caller gates [withSudo] behind the app lock, as every use of the saved password is.
  Future<void> load(Server server, {bool? withSudo}) async {
    final sudo = withSudo ?? (_states[server.id]?.elevated ?? false);
    final generation = (_generations[server.id] ?? 0) + 1;
    _generations[server.id] = generation;
    final previous = _states[server.id];
    _states[server.id] = SystemSpecsState(
      specs: previous?.specs,
      loading: true,
      elevated: previous?.elevated ?? false,
    );
    _notify();

    SystemSpecsState next;
    try {
      final ssh = transport;
      if (ssh == null) throw StateError('Monitoring is unavailable in this build.');
      final creds = resolveCredentials(
        server,
        keys: await _app.repository.getAllKeys(),
        profiles: await _app.repository.getAllProfiles(),
      );
      Future<String> exec(String command, {String? stdin}) =>
          ssh.exec(creds, command, stdin: stdin);
      final os = await _app.hostOs(server.id, exec);
      final password = sudo ? server.sudoPassword : null;
      final output = await exec(
        systemSpecsCommand(os, sudoPassword: password),
        stdin: password == null ? null : sudoStdin(password),
      );
      next = output.startsWith('SSH Error')
          ? _failed(server.id, output.removePrefix('SSH Error:').trim())
          : SystemSpecsState(specs: parseSystemSpecs(os, output), elevated: sudo);
    } on CredentialResolutionException catch (e) {
      next = _failed(server.id, e.message);
    } catch (e) {
      next = _failed(server.id, e is StateError ? e.message : e.toString());
    }
    // A newer read for this host, or the host being forgotten, replaced this one.
    if (_generations[server.id] != generation) return;
    _states[server.id] = next;
    _notify();
  }

  /// Reads [server]'s specs unless they are already shown or on their way.
  void loadIfNeeded(Server server) {
    final state = _states[server.id];
    if (state?.specs == null && state?.loading != true) load(server);
  }

  SystemSpecsState _failed(int serverId, String error) {
    final previous = _states[serverId];
    return SystemSpecsState(
      specs: previous?.specs,
      error: error,
      elevated: previous?.elevated ?? false,
    );
  }

  /// Whether the section or device [key] is expanded on [serverId]'s sheet.
  bool isExpanded(int serverId, String key) => _expanded[serverId]?.contains(key) ?? false;

  void toggleExpanded(int serverId, String key) {
    final keys = _expanded.putIfAbsent(serverId, () => {});
    if (!keys.remove(key)) keys.add(key);
    _notify();
  }

  void _forget(int serverId) {
    _generations[serverId] = (_generations[serverId] ?? 0) + 1;
    _expanded.remove(serverId);
    if (_states.remove(serverId) != null) _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _app.onHostForgotten.remove(_forget);
    super.dispose();
  }
}
