import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omniterm/data/alert_presets.dart';
import 'package:omniterm/data/app_database.dart';
import 'package:omniterm/data/app_repository.dart';
import 'package:omniterm/data/script_presets.dart';
import 'package:omniterm/data/ssh/secure_host_key_store.dart';
import 'package:omniterm/data/ssh/ssh_host_key_trust.dart';
import 'package:omniterm/platform/secret_store.dart';
import 'package:omniterm/ui/view_model/app_state.dart';
import 'package:omniterm/ui/view_model/backup_view_model.dart';

import 'support/fake_secure_storage.dart';

/// The Kotlin app's export for the rows seeded below, byte for byte.
///
/// `test/fixtures/backup/kotlin_export_golden.json` was produced by Kotlin's own
/// `AppViewModel.buildBackupJson` + `backupSettingsSnapshot` (Robolectric, so Android's real
/// `org.json` serializer) from these same rows on a fresh install with default settings. A backup
/// written by Flutter must be the file Kotlin writes: same sections and order, `\/` escaping,
/// integral numbers without `.0`, omitted nulls, pristine presets skipped, host-scoped rows
/// filtered and the full settings snapshot with Kotlin's defaults.
void main() {
  late AppDatabase db;
  late AppRepository repo;
  late AppState app;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    repo = AppRepository(db, SecretStore(storage: FakeSecureStorage(<String, String>{})));
    app = AppState(repo);
  });

  tearDown(() async {
    app.dispose();
    await db.close();
  });

  Server server(
    int id,
    String name,
    String host,
    String username, {
    int port = 22,
    String? groupName = 'Default',
    String serverColor = 'Default',
    String authType = 'password',
    String? authKeyAlias,
    String? authPassword,
    String sudoPassword = '',
    int? authProfileId,
    String notes = '',
    int keepAlive = 30,
    bool sshCompression = false,
    bool persistentSession = false,
    String proxyCommand = '',
    String proxyType = 'none',
    String proxyHost = '',
    int proxyPort = 0,
    String proxyUser = '',
    String proxyPassword = '',
    String? proxyKeyAlias,
    bool agentForwarding = false,
  }) => Server(
    id: id,
    name: name,
    host: host,
    port: port,
    username: username,
    groupName: groupName,
    serverColor: serverColor,
    authType: authType,
    authKeyAlias: authKeyAlias,
    authPassword: authPassword,
    sudoPassword: sudoPassword,
    authProfileId: authProfileId,
    notes: notes,
    keepAlive: keepAlive,
    sshCompression: sshCompression,
    persistentSession: persistentSession,
    proxyCommand: proxyCommand,
    proxyType: proxyType,
    proxyHost: proxyHost,
    proxyPort: proxyPort,
    proxyUser: proxyUser,
    proxyPassword: proxyPassword,
    proxyKeyAlias: proxyKeyAlias,
    agentForwarding: agentForwarding,
    healthScore: -1,
    lastLatency: 0,
    status: 'offline',
    authStatus: 'unknown',
  );

  QuickScriptsCompanion preset(int id, ScriptPreset p, {String? command, String notes = ''}) =>
      QuickScriptsCompanion.insert(
        id: Value(id),
        emoji: p.emoji,
        name: p.name,
        command: command ?? p.command,
        color: p.color,
        category: Value(p.category),
        sortOrder: Value(p.sortOrder),
        availableForQuick: Value(p.availableForQuick),
        availableForFleet: Value(p.availableForFleet),
        notes: Value(notes),
        presetKey: Value(p.presetKey),
      );

  AlertRulesCompanion presetRule(int id, String key, {String triggerWindow = '5m'}) {
    final p = kAlertPresets.singleWhere((preset) => preset.presetKey == key);
    return AlertRulesCompanion.insert(
      id: Value(id),
      serverId: 0,
      metricName: p.metricName,
      thresholdValue: p.thresholdValue,
      severity: p.severity,
      triggerWindow: Value(triggerWindow),
      presetKey: Value(p.presetKey),
    );
  }

  test('a Flutter export is byte-identical to the Kotlin export of the same data', () async {
    await repo.insertProfile(
      const CredentialProfile(
        id: 7,
        profileName: 'Ops',
        username: 'ops',
        authType: 'password',
        password: 's3cr3t',
        groupName: 'General',
      ),
    );
    await repo.insertProfile(
      const CredentialProfile(
        id: 8,
        profileName: 'Keys',
        username: 'deploy',
        authType: 'key',
        keyAlias: 'id_ed25519',
        groupName: 'Infra',
      ),
    );
    await repo.insertServer(
      server(
        1,
        'Prod / API',
        '10.0.0.5',
        'deploy',
        port: 2222,
        groupName: 'Work',
        serverColor: 'Blue',
        authPassword: 'p@ss/word"q',
        sudoPassword: 'sudo\tpw',
        notes: "line1\nline2 — ünïcödé ✓ <tag> & 'q'",
        keepAlive: 45,
        sshCompression: true,
        persistentSession: true,
        proxyType: 'http',
        proxyHost: 'proxy.local',
        proxyPort: 3128,
        proxyUser: 'pu',
        proxyPassword: 'pp',
        agentForwarding: true,
      ),
    );
    await repo.insertServer(
      server(
        2,
        'Lab',
        'lab.example',
        'ops',
        groupName: null,
        authType: 'profile',
        authProfileId: 7,
      ),
    );
    await repo.insertServer(
      server(
        3,
        'Key host',
        '192.168.1.9',
        'pi',
        authType: 'key',
        authKeyAlias: 'id_ed25519',
        proxyCommand: 'ssh -W %h:%p jump',
        proxyKeyAlias: 'jump',
      ),
    );
    await repo.insertKey(
      const SshKey(
        id: 0,
        alias: 'id_ed25519',
        keyType: 'Ed25519',
        privateKey:
            '-----BEGIN OPENSSH PRIVATE KEY-----\nb3Bl/bnNz+aC1rZXk=\n'
            '-----END OPENSSH PRIVATE KEY-----\n',
        publicKey: 'ssh-ed25519 AAAAC3Nz/aC1lZDI1NTE5 user@host',
        fingerprint: 'SHA256:ab/cd+ef',
      ),
    );
    await repo.insertScript(
      QuickScriptsCompanion.insert(
        id: const Value(1),
        emoji: '🔧',
        name: 'Restart nginx',
        command: 'sudo systemctl restart nginx && echo "done"',
        color: 'green',
        longRunning: const Value(true),
        category: const Value('Web'),
        sortOrder: const Value(3),
        availableForFleet: const Value(true),
        targetOs: const Value('Linux'),
        targetSystem: const Value('Debian'),
        notes: const Value('careful'),
      ),
    );
    final homelab = {for (final p in kHomelabPresets) p.presetKey: p};
    await repo.insertScript(preset(2, homelab['homelab.pve_vms']!));
    await repo.insertScript(preset(3, homelab['homelab.pve_containers']!, notes: 'edited'));
    final cluster = homelab['homelab.pve_cluster']!;
    await repo.insertScript(preset(4, cluster, command: '${cluster.command} # mine'));
    await repo.insertRule(presetRule(31, 'alert.cpu'));
    await repo.insertRule(presetRule(32, 'alert.memory'));
    await repo.insertRule(presetRule(33, 'alert.disk', triggerWindow: '10m'));
    await repo.insertRule(
      AlertRulesCompanion.insert(
        id: const Value(34),
        serverId: 1,
        metricName: 'Disk Usage',
        mountPoint: const Value('/var'),
        thresholdValue: 85.5,
        severity: 'WARNING',
        notes: const Value('var fills'),
      ),
    );
    await repo.insertRule(
      AlertRulesCompanion.insert(
        id: const Value(35),
        serverId: 99,
        metricName: 'CPU Usage',
        thresholdValue: 70,
        severity: 'WARNING',
      ),
    );
    await repo.insertAlert(
      ActiveAlertsCompanion.insert(
        id: const Value(21),
        ruleId: 32,
        serverId: 1,
        metricName: 'Memory Usage',
        currentValue: 95.5,
        thresholdValue: 90,
        severity: 'CRITICAL',
        triggeredTime: 1786406400000,
        acknowledged: const Value(true),
      ),
    );
    await repo.insertAlert(
      ActiveAlertsCompanion.insert(
        id: const Value(22),
        ruleId: 35,
        serverId: 99,
        metricName: 'CPU Usage',
        currentValue: 75,
        thresholdValue: 70,
        severity: 'WARNING',
        triggeredTime: 1786406500000,
      ),
    );
    await repo.insertAlertHistory(
      AlertHistoryCompanion.insert(
        activeAlertId: 21,
        serverId: 1,
        serverName: 'Prod / API',
        metricName: 'Memory Usage',
        currentValue: 95.5,
        thresholdValue: 90,
        severity: 'CRITICAL',
        triggeredTime: 1786406400000,
        historyTime: 1786406460000,
        status: 'RESOLVED',
      ),
    );
    await repo.insertAlertHistory(
      AlertHistoryCompanion.insert(
        activeAlertId: 22,
        serverId: 99,
        serverName: 'Gone',
        metricName: 'CPU Usage',
        currentValue: 75,
        thresholdValue: 70,
        severity: 'WARNING',
        triggeredTime: 1786406500000,
        historyTime: 1786406560000,
        status: 'ACTIVE',
      ),
    );
    await repo.insertWolTarget(
      WolTargetsCompanion.insert(
        name: 'NAS',
        macAddress: 'AA:BB:CC:DD:EE:FF',
        ipAddress: const Value('192.168.1.20'),
        lastWokenTime: const Value(1786406400000),
      ),
    );
    await repo.insertNetworkShare(
      const NetworkShare(
        id: 4,
        name: 'Media',
        protocol: 'SMB',
        address: '192.168.1.20',
        port: 445,
        sharePath: '/media/movies',
        workgroup: 'WORKGROUP',
        username: 'guest',
        password: 'pw',
        authProfileId: 7,
        anonymous: false,
        useHttps: false,
        notes: '',
        lastChecked: 1786406400000,
        lastStatus: 'online',
      ),
    );
    await repo.insertPortForward(
      PortForwardsCompanion.insert(
        id: const Value(5),
        serverId: 1,
        name: 'DB',
        bindPort: 15432,
        destHost: const Value('db.internal'),
        destPort: const Value(5432),
        autoStart: const Value(true),
      ),
    );
    await repo.insertPortForward(
      PortForwardsCompanion.insert(
        id: const Value(6),
        serverId: 99,
        name: 'Orphan',
        bindPort: 18080,
      ),
    );
    await repo.insertSetting('flag_secure', 'false');
    await repo.insertSetting('hide_sensitive_info', 'true');
    await repo.insertSetting('sftp_bookmarks_1', '/var/log\n/etc');
    await repo.insertSetting('app_pin', '1234');
    await repo.insertSetting('sftp_last_path_1', '/tmp');

    await app.start();
    await Future<void>.delayed(Duration.zero);
    final vm = BackupViewModel(
      app,
      hostKeyTrust: SshHostKeyTrust(
        SecureHostKeyStore(storage: FakeSecureStorage(<String, String>{})),
      ),
      // The document itself is under test here; the envelope has its own tests.
      encrypt: (json, passphrase) async => json,
    );
    await vm.loadSelection();
    final exported = await vm.exportBackup('a-long-enough-passphrase');
    expect(vm.error, isNull);
    expect(exported, File('test/fixtures/backup/kotlin_export_golden.json').readAsStringSync());
    vm.dispose();
  });
}
