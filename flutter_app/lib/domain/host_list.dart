/// The Hosts tab's sorting, copied SSH command and Wake-on-LAN match, ported from `HostSort`,
/// `sortHosts` and `sshCommandFor` in `ui/AppViewModel.kt` and `wolTargetFor` in `ui/HostActions.kt`.
library;

import 'package:collection/collection.dart' show mergeSort;

import '../data/app_database.dart';

/// Orders for the Hosts list, with the value each is saved as under `host_sort`. Ties keep the name
/// order the list is loaded in.
enum HostSort {
  name('name', 'Name'),
  status('status', 'Status (online first)'),
  health('health', 'Health (lowest first)'),
  latency('latency', 'Latency (fastest first)');

  const HostSort(this.settingValue, this.label);

  final String settingValue;
  final String label;

  /// The `host_sort` setting key.
  static const settingKey = 'host_sort';

  static HostSort fromSetting(String? value) =>
      HostSort.values.firstWhere((sort) => sort.settingValue == value, orElse: () => HostSort.name);
}

/// [hosts] (loaded by name) in [sort] order. Status puts online hosts first, then those being
/// checked, then offline ones. Health puts the lowest scores first, so hosts needing attention lead,
/// and hosts without a score (below zero) last. Latency is fastest first, with hosts that are not
/// online last. Stable, as Kotlin's `sortedBy` is.
List<Server> sortHosts(List<Server> hosts, HostSort sort, int Function(Server) health) {
  const last = 1 << 62;
  final int Function(Server)? key = switch (sort) {
    HostSort.name => null,
    HostSort.status => (s) => switch (s.status) {
      'online' => 0,
      'connecting' => 1,
      _ => 2,
    },
    HostSort.health => (s) => health(s) < 0 ? last : health(s),
    HostSort.latency => (s) => s.status == 'online' ? s.lastLatency : last,
  };
  if (key == null) return hosts;
  final sorted = [...hosts];
  mergeSort(sorted, compare: (a, b) => key(a).compareTo(key(b)));
  return sorted;
}

/// An OpenSSH command line reaching [server] as [username], through its jump host or proxy when it
/// has one, for pasting into a terminal elsewhere. Carries no secrets.
String sshCommandFor(Server server, String username) {
  String hostPort(String host, int port) =>
      port > 0 && port != 22 ? '${host.contains(':') ? '[$host]' : host}:$port' : host;
  final hasProxy = server.proxyHost.trim().isNotEmpty;
  final proxy = hostPort(server.proxyHost, server.proxyPort);
  return [
    'ssh',
    ...switch (server.proxyType) {
      'ssh' when hasProxy => [
        '-J',
        '${server.proxyUser.trim().isNotEmpty ? '${server.proxyUser}@' : ''}$proxy',
      ],
      'socks5' when hasProxy => ['-o', "'ProxyCommand=nc -X 5 -x $proxy %h %p'"],
      'http' when hasProxy => ['-o', "'ProxyCommand=nc -X connect -x $proxy %h %p'"],
      _ => const <String>[],
    },
    if (server.port != 22) ...['-p', '${server.port}'],
    '$username@${server.host}',
  ].join(' ');
}

/// The Wake-on-LAN target at [server]'s address. A target without an address never matches, even
/// by name.
WolTarget? wolTargetFor(Server server, List<WolTarget> targets) {
  final host = server.host.trim().toLowerCase();
  for (final target in targets) {
    final address = target.ipAddress.trim();
    if (address.isNotEmpty && address.toLowerCase() == host) return target;
  }
  return null;
}
