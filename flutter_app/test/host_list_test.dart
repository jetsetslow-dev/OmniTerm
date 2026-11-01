import 'package:flutter_test/flutter_test.dart';
import 'package:omniterm/data/app_database.dart';
import 'package:omniterm/domain/host_list.dart';

/// The Hosts tab's sorting, copied SSH command and Wake-on-LAN match, as Kotlin's `HostListTest`.
void main() {
  Server host(int id, String name, {String status = 'online', int latency = 10, String? host}) =>
      Server(
        id: id,
        name: name,
        host: host ?? '$name.lan',
        port: 22,
        username: 'admin',
        serverColor: 'Default',
        authType: 'password',
        sudoPassword: '',
        notes: '',
        keepAlive: 30,
        sshCompression: false,
        persistentSession: false,
        proxyCommand: '',
        proxyType: 'none',
        proxyHost: '',
        proxyPort: 0,
        proxyUser: '',
        proxyPassword: '',
        agentForwarding: false,
        healthScore: 100,
        lastLatency: latency,
        status: status,
        authStatus: 'ok',
      );

  // Loaded by name, as the database returns them.
  final hosts = [
    host(1, 'alpha', status: 'offline'),
    host(2, 'bravo', latency: 40),
    host(3, 'charlie', status: 'connecting'),
    host(4, 'delta', latency: 5),
  ];
  const health = {1: -1, 2: 80, 3: 30, 4: 95};

  List<String> order(HostSort sort) =>
      sortHosts(hosts, sort, (s) => health[s.id]!).map((s) => s.name).toList();

  test('name keeps the loaded order', () {
    expect(order(HostSort.name), ['alpha', 'bravo', 'charlie', 'delta']);
  });

  test('status puts online hosts first and keeps names in order within each', () {
    expect(order(HostSort.status), ['bravo', 'delta', 'charlie', 'alpha']);
  });

  test('health puts the lowest score first and unscored hosts last', () {
    expect(order(HostSort.health), ['charlie', 'bravo', 'delta', 'alpha']);
  });

  test('latency is fastest first with hosts that are not online last', () {
    expect(order(HostSort.latency), ['delta', 'bravo', 'alpha', 'charlie']);
  });

  test('an unknown saved sort falls back to name', () {
    expect(HostSort.fromSetting('bogus'), HostSort.name);
    expect(HostSort.fromSetting(null), HostSort.name);
    expect(HostSort.fromSetting('health'), HostSort.health);
  });

  test('the ssh command names the port only when it is not 22', () {
    expect(sshCommandFor(host(1, 'nas'), 'admin'), 'ssh admin@nas.lan');
    expect(sshCommandFor(host(1, 'nas').copyWith(port: 2222), 'root'), 'ssh -p 2222 root@nas.lan');
  });

  test('the ssh command goes through the jump host or proxy', () {
    final jump = host(
      1,
      'db',
    ).copyWith(proxyType: 'ssh', proxyHost: 'bastion', proxyPort: 2200, proxyUser: 'ops');
    expect(sshCommandFor(jump, 'admin'), 'ssh -J ops@bastion:2200 admin@db.lan');
    final socks = host(
      1,
      'db',
    ).copyWith(proxyType: 'socks5', proxyHost: 'fe80::1', proxyPort: 1080);
    expect(
      sshCommandFor(socks, 'admin'),
      "ssh -o 'ProxyCommand=nc -X 5 -x [fe80::1]:1080 %h %p' admin@db.lan",
    );
    final http = host(1, 'db').copyWith(proxyType: 'http', proxyHost: 'proxy', proxyPort: 22);
    expect(
      sshCommandFor(http, 'admin'),
      "ssh -o 'ProxyCommand=nc -X connect -x proxy %h %p' admin@db.lan",
    );
    // A proxy type without a proxy host adds nothing.
    expect(sshCommandFor(host(1, 'db').copyWith(proxyType: 'ssh'), 'admin'), 'ssh admin@db.lan');
  });

  test('a wake target matches the host by address only', () {
    const targets = [
      WolTarget(
        id: 1,
        name: 'nas',
        macAddress: '00:11:22:33:44:55',
        broadcastIp: '255.255.255.255',
        ipAddress: '',
        port: 9,
        notes: '',
        lastWokenTime: 0,
      ),
      WolTarget(
        id: 2,
        name: 'desk',
        macAddress: '00:11:22:33:44:66',
        broadcastIp: '255.255.255.255',
        ipAddress: ' 192.168.1.20 ',
        port: 9,
        notes: '',
        lastWokenTime: 0,
      ),
    ];
    expect(wolTargetFor(host(1, 'desk', host: '192.168.1.20'), targets)?.id, 2);
    // A target without an address never matches, even by name.
    expect(wolTargetFor(host(1, 'nas', host: 'nas.lan'), targets), isNull);
  });
}
