import 'package:flutter/foundation.dart';

import '../data/app_database.dart';

/// App-wide "Hide sensitive info" switch, ported from `ui/HostDisplay.kt`.
///
/// When on, saved endpoints are identified by their user-given names instead of IPs/hostnames
/// (screen-share/screenshot safe). **Display-only:** connections always use the real host.
///
/// The Kotlin was a Compose-observable `object` holding a `mutableStateOf`, so deep leaf composables
/// did not need the ViewModel threaded through just to render a label. The Dart equivalent is a
/// [ChangeNotifier] singleton; widgets rebuild by listening to [instance] (via
/// `ListenableBuilder`/`AnimatedBuilder`), and the free functions below stay callable from anywhere.
class HostDisplay extends ChangeNotifier {
  HostDisplay._();

  static final HostDisplay instance = HostDisplay._();

  bool _hideSensitiveInfo = false;

  bool get hideSensitiveInfo => _hideSensitiveInfo;

  set hideSensitiveInfo(bool value) {
    if (_hideSensitiveInfo == value) return;
    _hideSensitiveInfo = value;
    notifyListeners();
  }

  /// Address-position text for a server: its name when sensitive info is hidden.
  String host(Server srv) =>
      _hideSensitiveInfo ? (srv.name.trim().isEmpty ? 'host' : srv.name) : srv.host;

  /// Name-position text for a server (blank names fall back to the address when allowed).
  String name(Server srv) {
    if (srv.name.trim().isNotEmpty) return srv.name;
    return _hideSensitiveInfo ? 'host' : srv.host;
  }

  /// The usual "user@host" line, honouring the hide-sensitive-info mode.
  String userAtHost(Server srv) => '${srv.username}@${host(srv)}';

  /// Address-position text for a network share.
  String address(NetworkShare share) =>
      _hideSensitiveInfo ? (share.name.trim().isEmpty ? 'share' : share.name) : share.address;

  /// Generic mask for sensitive values with no name to substitute (MACs, tunnel endpoints).
  String sensitive(String value) => _hideSensitiveInfo ? '•••' : value;
}

/// Whether to warn that a host looks offline before connecting to it.
///
/// Ported from the gate in `connectTerminal` (`ui/AppViewModel.kt:4496`).
///
/// [probed] is the part that matters. A host's stored status is `offline` until the first
/// reachability check answers, so status alone cannot tell "we looked, and it is down" from "nobody
/// has looked yet" — and warning about a host the user has just added is a false alarm at the exact
/// moment they first connect, which teaches people to dismiss the warning that matters.
bool shouldWarnHostOffline({required bool probed, required String status}) =>
    probed && status != 'online';
