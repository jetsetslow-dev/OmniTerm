import 'package:flutter_test/flutter_test.dart';
import 'package:omniterm/data/app_database.dart';
import 'package:omniterm/data/remote_models.dart';
import 'package:omniterm/domain/host_display.dart';
import 'package:omniterm/domain/monitor_history.dart';
import 'package:omniterm/domain/script_filters.dart';

/// Covers the domain ports that operate on drift-generated row types.
///
/// Ported from `HostDisplayMaskingTest.kt` and `MonitorHistoryTest.kt`, plus the host-targeting
/// half of `ScriptFilters`.
void main() {
  QuickScript script({
    String targetOs = 'Any',
    String targetSystem = 'Any',
    String category = 'General',
    bool availableForQuick = true,
  }) => QuickScript(
    id: 1,
    emoji: '⚡',
    name: 'Test',
    command: 'true',
    color: 'cyan',
    longRunning: false,
    category: category,
    sortOrder: 0,
    availableForQuick: availableForQuick,
    availableForFleet: false,
    targetOs: targetOs,
    targetSystem: targetSystem,
    notes: '',
  );

  HostMetrics metrics({String os = 'Linux', Set<String> platforms = const {'linux'}}) =>
      HostMetrics(
        cpuPercent: 0,
        memUsedBytes: 0,
        memTotalBytes: 0,
        diskUsedBytes: 0,
        diskTotalBytes: 0,
        load1: 0,
        load5: 0,
        load15: 0,
        uptimeSeconds: 0,
        procCount: 0,
        os: os,
        platforms: platforms,
      );

  group('quickScriptMatchesHost', () {
    test('a script not offered for quick actions never matches', () {
      expect(quickScriptMatchesHost(script(availableForQuick: false), metrics()), isFalse);
    });

    test('"Any" targets match every host', () {
      expect(quickScriptMatchesHost(script(), metrics()), isTrue);
      expect(
        quickScriptMatchesHost(script(), metrics(os: 'Windows', platforms: {'windows'})),
        isTrue,
      );
      expect(
        quickScriptMatchesHost(script(), null),
        isTrue,
        reason: 'an unprobed host must not hide every script',
      );
    });

    test('an OS target matches the detected OS case-insensitively', () {
      expect(quickScriptMatchesHost(script(targetOs: 'Linux'), metrics(os: 'Linux')), isTrue);
      expect(quickScriptMatchesHost(script(targetOs: 'linux'), metrics(os: 'Linux')), isTrue);
      expect(quickScriptMatchesHost(script(targetOs: 'Windows'), metrics(os: 'Linux')), isFalse);
    });

    test('an OS target also matches via the platform set', () {
      // On Linux the `os` field carries the distro pretty-name, so the bare family only appears in
      // the platform set — matching on `os` alone would hide every Linux-targeted script.
      expect(
        quickScriptMatchesHost(script(targetOs: 'Linux'), metrics(os: 'Raspberry Pi OS')),
        isTrue,
      );
    });

    test('a system target must appear in the detected platforms', () {
      expect(
        quickScriptMatchesHost(
          script(targetSystem: 'Proxmox'),
          metrics(platforms: {'linux', 'proxmox'}),
        ),
        isTrue,
      );
      expect(
        quickScriptMatchesHost(script(targetSystem: 'Proxmox'), metrics()),
        isFalse,
        reason: 'a Proxmox helper must not appear on a plain Linux host',
      );
      expect(
        quickScriptMatchesHost(
          script(targetSystem: 'Home Assistant'),
          metrics(platforms: {'linux', 'homeassistant'}),
        ),
        isTrue,
      );
    });

    test('a legacy category still filters when the row predates targeting', () {
      expect(
        quickScriptMatchesHost(script(category: 'Proxmox'), metrics(platforms: {'linux'})),
        isFalse,
      );
      expect(
        quickScriptMatchesHost(
          script(category: 'Proxmox'),
          metrics(platforms: {'linux', 'proxmox'}),
        ),
        isTrue,
      );
    });

    test('an unrecognised category does not filter', () {
      expect(quickScriptMatchesHost(script(category: 'Backups'), metrics()), isTrue);
    });
  });

  group('HostDisplay masking', () {
    final display = HostDisplay.instance;

    Server server({String name = 'nas', String host = '10.0.0.2'}) => Server(
      id: 1,
      name: name,
      host: host,
      port: 22,
      username: 'root',
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
      lastLatency: 0,
      status: 'offline',
      authStatus: 'unknown',
    );

    NetworkShare share({String name = 'media', String address = '10.0.0.5'}) => NetworkShare(
      id: 1,
      name: name,
      protocol: 'SMB',
      address: address,
      port: 445,
      sharePath: '',
      workgroup: '',
      username: '',
      password: '',
      anonymous: true,
      useHttps: false,
      notes: '',
      lastChecked: 0,
      lastStatus: 'unknown',
    );

    setUp(() => display.hideSensitiveInfo = false);
    tearDown(() => display.hideSensitiveInfo = false);

    test('addresses show normally when masking is off', () {
      expect(display.host(server()), '10.0.0.2');
      expect(display.userAtHost(server()), 'root@10.0.0.2');
      expect(display.address(share()), '10.0.0.5');
      expect(display.sensitive('AA:BB:CC:DD:EE:FF'), 'AA:BB:CC:DD:EE:FF');
    });

    test('masking substitutes the user-given name for the address', () {
      display.hideSensitiveInfo = true;
      expect(display.host(server()), 'nas');
      expect(display.userAtHost(server()), 'root@nas');
      expect(display.address(share()), 'media');
      expect(display.sensitive('AA:BB:CC:DD:EE:FF'), '•••');
    });

    test('a blank name falls back to a placeholder, never the address', () {
      display.hideSensitiveInfo = true;
      expect(display.host(server(name: '')), 'host');
      expect(display.host(server(name: '   ')), 'host');
      expect(display.address(share(name: '')), 'share');
    });

    test('the name position falls back to the address only while unmasked', () {
      expect(display.name(server(name: '')), '10.0.0.2');
      display.hideSensitiveInfo = true;
      expect(
        display.name(server(name: '')),
        'host',
        reason: 'leaking the address into the name position would defeat masking',
      );
      expect(display.name(server()), 'nas');
    });

    test('toggling notifies listeners so leaf widgets rebuild', () {
      var notifications = 0;
      void listener() => notifications++;
      display.addListener(listener);
      addTearDown(() => display.removeListener(listener));

      display.hideSensitiveInfo = true;
      expect(notifications, 1);
      display.hideSensitiveInfo = true;
      expect(notifications, 1, reason: 'setting the same value must not notify');
      display.hideSensitiveInfo = false;
      expect(notifications, 2);
    });
  });

  group('buildHourlyMetricSeries', () {
    const hour = 3600000;

    MetricHistoryRow row(int ts, double cpu, double ram, [double? temp]) => MetricHistoryRow(
      id: 0,
      serverId: 1,
      timestamp: ts,
      cpuUsage: cpu,
      ramUsage: ram,
      diskUsage: 0,
      latency: 0,
      networkIn: 0,
      networkOut: 0,
      cpuTemperatureC: temp,
    );

    test('averages samples within each clock hour', () {
      final series = buildHourlyMetricSeries([
        row(hour * 3 + 1000, 10, 50),
        row(hour * 3 + 2000, 30, 70),
        row(hour * 4 + 1000, 80, 20),
      ]);

      expect(series.cpu, hasLength(2));
      expect(series.cpu[0].timestamp, hour * 3);
      expect(series.cpu[0].value, closeTo(20, 0.001));
      expect(series.ram[0].value, closeTo(60, 0.001));
      expect(series.cpu[1].value, closeTo(80, 0.001));
    });

    test('buckets are ordered by hour regardless of input order', () {
      final series = buildHourlyMetricSeries([
        row(hour * 9, 90, 0),
        row(hour * 2, 20, 0),
        row(hour * 5, 50, 0),
      ]);
      expect(series.cpu.map((p) => p.timestamp).toList(), [hour * 2, hour * 5, hour * 9]);
    });

    test('an hour with no sensor reading is omitted rather than zeroed', () {
      final series = buildHourlyMetricSeries([row(hour * 1, 10, 10, 40), row(hour * 2, 10, 10)]);
      expect(series.cpu, hasLength(2));
      expect(
        series.temperature,
        hasLength(1),
        reason: 'a host with no thermal sensor must not appear to run at 0°C',
      );
      expect(series.temperature.single.timestamp, hour * 1);
    });

    test('temperature averages only the hours that reported one', () {
      final series = buildHourlyMetricSeries([
        row(hour, 0, 0, 40),
        row(hour, 0, 0),
        row(hour, 0, 0, 60),
      ]);
      expect(series.temperature.single.value, closeTo(50, 0.001));
    });

    test('empty history yields empty series', () {
      final series = buildHourlyMetricSeries([]);
      expect(series.cpu, isEmpty);
      expect(series.ram, isEmpty);
      expect(series.temperature, isEmpty);
    });
  });

  group('chartEndpointLabels', () {
    const hour = 3600000;
    // Fixed UTC instants so the assertions never depend on the machine's zone.
    const noon = 1767355200000; // 2026-01-02T12:00:00Z

    test('empty input yields placeholders', () {
      expect(chartEndpointLabels(const []), ('—', '—'));
    });

    test('a sub-hour range keeps seconds', () {
      final labels = chartEndpointLabels([noon, noon + 90000], locale: 'en_US', utc: true);
      expect(labels, ('12:00:00', '12:01:30'));
    });

    test('a same-day range beyond an hour drops seconds', () {
      final labels = chartEndpointLabels([noon, noon + 3 * hour], locale: 'en_US', utc: true);
      expect(labels, ('12:00', '15:00'));
    });

    test('a range crossing midnight includes the date', () {
      final labels = chartEndpointLabels([noon, noon + 18 * hour], locale: 'en_US', utc: true);
      expect(labels.$1, 'Jan 2 12:00');
      expect(labels.$2, 'Jan 3 06:00');
    });

    test('a short range that still crosses the calendar day gets a date', () {
      // 23:59 -> 00:01 is two minutes apart but ambiguous without a date.
      const beforeMidnight = 1767398340000; // 2026-01-02T23:59:00Z
      final labels = chartEndpointLabels(
        [beforeMidnight, beforeMidnight + 120000],
        locale: 'en_US',
        utc: true,
      );
      expect(labels.$1, 'Jan 2 23:59');
      expect(labels.$2, 'Jan 3 00:01');
    });
  });
}
