import 'dart:convert';

import 'package:drift/drift.dart' show Value;

import '../../domain/backup_selection.dart';
import '../app_database.dart';
import '../app_repository.dart';
import '../script_presets.dart';
import 'backup_envelope.dart';

/// Turns the database into a backup document, and back.
///
/// **Only what the user created or changed is exported.** A pristine seeded preset is the app's own
/// content: a fresh install re-seeds it, so carrying it in a backup would duplicate defaults on
/// restore. An *edited* preset is effectively the user's and is kept, with its key, so the preset
/// toggle can still remove it afterwards rather than treating it as custom.
///
/// Ids are exported only for the rows other rows point at — hosts, profiles and alert rules — and
/// are remapped on restore. Everything else is restored with fresh ids: a backup is content, not a
/// snapshot of a rowid space.
class BackupPayload {
  const BackupPayload._();

  /// The document version this app writes.
  static const version = 2;

  /// Serialises the selected sections.
  static String encode({
    required BackupSelection selection,
    required List<Server> servers,
    required List<SshKey> keys,
    required List<CredentialProfile> profiles,
    required List<QuickScript> scripts,
    required List<AlertRule> rules,
    required List<WolTarget> wolTargets,
    required List<PortForward> portForwards,
    required List<AppSetting> settings,
    List<ActiveAlert> activeAlerts = const [],
    List<AlertHistoryRow> alertHistory = const [],
    List<NetworkShare> networkShares = const [],
  }) {
    final closed = selection.withReferentialClosure();

    final document = <String, dynamic>{'v': version};

    if (closed.contains(BackupSection.servers)) {
      document['servers'] = [
        for (final server in servers)
          {
            // Exported so server-scoped rows can be re-pointed at the restored host.
            'id': server.id,
            'name': server.name,
            'host': server.host,
            'port': server.port,
            'username': server.username,
            'groupName': server.groupName,
            'serverColor': server.serverColor,
            'authType': server.authType,
            'authKeyAlias': server.authKeyAlias,
            'authPassword': server.authPassword,
            'sudoPassword': server.sudoPassword,
            'authProfileId': server.authProfileId,
            'notes': server.notes,
            'keepAlive': server.keepAlive,
            'sshCompression': server.sshCompression,
            'persistentSession': server.persistentSession,
            'agentForwarding': server.agentForwarding,
            'proxyType': server.proxyType,
            'proxyHost': server.proxyHost,
            'proxyPort': server.proxyPort,
            'proxyUser': server.proxyUser,
            'proxyPassword': server.proxyPassword,
            'proxyKeyAlias': server.proxyKeyAlias,
          },
      ];
    }

    if (closed.contains(BackupSection.sshKeys)) {
      document['sshKeys'] = [
        for (final key in keys)
          {
            'alias': key.alias,
            'keyType': key.keyType,
            'privateKey': key.privateKey,
            'publicKey': key.publicKey,
            'fingerprint': key.fingerprint,
          },
      ];
    }

    if (closed.contains(BackupSection.credentialProfiles)) {
      document['credentialProfiles'] = [
        for (final profile in profiles)
          {
            'id': profile.id,
            'profileName': profile.profileName,
            'username': profile.username,
            'authType': profile.authType,
            'password': profile.password,
            'keyAlias': profile.keyAlias,
            'groupName': profile.groupName,
          },
      ];
    }

    if (closed.contains(BackupSection.scripts)) {
      document['scripts'] = [
        for (final script in scripts.where((s) => !_isPristinePreset(s)))
          {
            'emoji': script.emoji,
            'name': script.name,
            'command': script.command,
            'color': script.color,
            'longRunning': script.longRunning,
            'category': script.category,
            'sortOrder': script.sortOrder,
            'availableForQuick': script.availableForQuick,
            'availableForFleet': script.availableForFleet,
            'targetOs': script.targetOs,
            'targetSystem': script.targetSystem,
            'notes': script.notes,
            // Kept so an edited preset stays identifiable after a restore, and the toggle can still
            // remove or reset it rather than treating it as a custom script.
            'presetKey': script.presetKey,
          },
      ];
    }

    if (closed.contains(BackupSection.alertRules)) {
      document['alertRules'] = [
        for (final rule in rules)
          {
            // The rule's own id travels because a firing alert points at it — the same reason hosts
            // and profiles carry theirs. Restore maps it to the new row rather than trusting it.
            'id': rule.id,
            'serverId': rule.serverId,
            'metricName': rule.metricName,
            'mountPoint': rule.mountPoint,
            'thresholdValue': rule.thresholdValue,
            'severity': rule.severity,
            'triggerWindow': rule.triggerWindow,
            'enabled': rule.enabled,
            'notes': rule.notes,
            'presetKey': rule.presetKey,
          },
      ];
    }

    if (closed.contains(BackupSection.portForwards)) {
      document['portForwards'] = [
        for (final pf in portForwards)
          {
            'serverId': pf.serverId,
            'name': pf.name,
            'kind': pf.kind,
            'bindHost': pf.bindHost,
            'bindPort': pf.bindPort,
            'destHost': pf.destHost,
            'destPort': pf.destPort,
            'autoStart': pf.autoStart,
          },
      ];
    }

    if (closed.contains(BackupSection.activeAlerts)) {
      document['activeAlerts'] = [
        for (final alert in activeAlerts)
          {
            'ruleId': alert.ruleId,
            'serverId': alert.serverId,
            'metricName': alert.metricName,
            'currentValue': alert.currentValue,
            'thresholdValue': alert.thresholdValue,
            'severity': alert.severity,
            'triggeredTime': alert.triggeredTime,
            'acknowledged': alert.acknowledged,
            'mutedUntil': alert.mutedUntil,
          },
      ];
    }

    if (closed.contains(BackupSection.alertHistory)) {
      document['alertHistory'] = [
        for (final row in alertHistory)
          {
            'activeAlertId': row.activeAlertId,
            'serverId': row.serverId,
            // The host's name is stored on the row, not looked up: an incident is a record of what
            // was true then, and a host renamed since must not rewrite its own history.
            'serverName': row.serverName,
            'metricName': row.metricName,
            'currentValue': row.currentValue,
            'thresholdValue': row.thresholdValue,
            'severity': row.severity,
            'triggeredTime': row.triggeredTime,
            'historyTime': row.historyTime,
            'status': row.status,
          },
      ];
    }

    if (closed.contains(BackupSection.networkShares)) {
      document['networkShares'] = [
        for (final share in networkShares)
          {
            'name': share.name,
            'protocol': share.protocol,
            'address': share.address,
            'port': share.port,
            'sharePath': share.sharePath,
            'workgroup': share.workgroup,
            'username': share.username,
            // The password travels because a share without it cannot be mounted, and this document
            // is already encrypted end to end (`backup_envelope.dart`). A backup that silently
            // dropped credentials would restore a list of shares that all fail to open.
            'password': share.password,
            'authProfileId': share.authProfileId,
            'anonymous': share.anonymous,
            'useHttps': share.useHttps,
            'notes': share.notes,
          },
      ];
    }

    if (closed.contains(BackupSection.wolTargets)) {
      document['wolTargets'] = [
        for (final target in wolTargets)
          {
            'name': target.name,
            'macAddress': target.macAddress,
            'broadcastIp': target.broadcastIp,
            'ipAddress': target.ipAddress,
            'port': target.port,
          },
      ];
    }

    if (closed.contains(BackupSection.settings)) {
      document['settings'] = [
        // The app lock PIN is a credential for *this device*, not a preference. Restoring it onto
        // another device would carry a lock the user did not set there.
        for (final setting in settings.where((s) => s.key != 'app_pin'))
          {'key': setting.key, 'value': setting.value},
      ];
    }

    return jsonEncode(document);
  }

  static bool _isPristinePreset(QuickScript script) {
    final key = script.presetKey;
    if (key == null) return false;
    final preset = kAllScriptPresets.where((p) => p.presetKey == key).firstOrNull;
    if (preset == null) return false;
    return isPristinePreset(preset, script.name, script.command);
  }

  /// Restores [json] into the database.
  ///
  /// Additive: existing rows are left alone and the backup's rows are inserted alongside them. A
  /// restore that wiped the device first would make "restore the wrong file" unrecoverable, and
  /// there is no undo for that.
  ///
  /// Returns a per-section count of what was written.
  static Future<Map<String, int>> restore(AppRepositoryLike repository, String json) async {
    final Map<String, dynamic> document;
    try {
      document = jsonDecode(json) as Map<String, dynamic>;
    } catch (_) {
      throw const BackupException('That backup file could not be read.');
    }

    final counts = <String, int>{};

    // Old host id → new host id, so alert rules land on the right machine.
    final serverIdMap = <int, int>{};
    for (final raw in _list(document, 'servers')) {
      final oldId = raw['id'] as int? ?? 0;
      final newId = await repository.insertRestoredServer(raw);
      if (oldId != 0) serverIdMap[oldId] = newId;
      counts['servers'] = (counts['servers'] ?? 0) + 1;
    }

    for (final raw in _list(document, 'sshKeys')) {
      await repository.insertRestoredKey(raw);
      counts['sshKeys'] = (counts['sshKeys'] ?? 0) + 1;
    }

    for (final raw in _list(document, 'credentialProfiles')) {
      await repository.insertRestoredProfile(raw);
      counts['credentialProfiles'] = (counts['credentialProfiles'] ?? 0) + 1;
    }

    for (final raw in _list(document, 'scripts')) {
      await repository.insertRestoredScript(raw);
      counts['scripts'] = (counts['scripts'] ?? 0) + 1;
    }

    for (final raw in _list(document, 'portForwards')) {
      final mapped = remapServerId(raw['serverId'] as int? ?? 0, serverIdMap);
      // A tunnel with no host has nothing to run over. Restoring it against an arbitrary host would
      // forward a port to a machine the user never chose — the same reasoning as an alert rule, with
      // a worse failure mode.
      if (mapped == null) {
        counts['portForwardsSkipped'] = (counts['portForwardsSkipped'] ?? 0) + 1;
        continue;
      }
      await repository.insertRestoredPortForward({...raw, 'serverId': mapped});
      counts['portForwards'] = (counts['portForwards'] ?? 0) + 1;
    }

    // Old rule id → new rule id, so a firing alert lands on the rule that raised it.
    final ruleIdMap = <int, int>{};
    for (final raw in _list(document, 'alertRules')) {
      final mapped = remapServerId(raw['serverId'] as int? ?? 0, serverIdMap);
      // A rule whose host was not in the backup has nothing to watch. Restoring it against an
      // arbitrary host would silently point it at the wrong machine.
      if (mapped == null) {
        counts['alertRulesSkipped'] = (counts['alertRulesSkipped'] ?? 0) + 1;
        continue;
      }
      final oldId = raw['id'] as int? ?? 0;
      final newId = await repository.insertRestoredRule({...raw, 'serverId': mapped});
      if (oldId != 0) ruleIdMap[oldId] = newId;
      counts['alertRules'] = (counts['alertRules'] ?? 0) + 1;
    }

    for (final raw in _list(document, 'activeAlerts')) {
      final server = remapServerId(raw['serverId'] as int? ?? 0, serverIdMap);
      final rule = remapServerId(raw['ruleId'] as int? ?? 0, ruleIdMap);
      // A firing alert is a claim that something is wrong *right now* on a particular host, raised
      // by a particular rule. Without both, it is a red banner about a machine nobody can check
      // against a threshold nobody can see — so it is skipped and counted rather than guessed at.
      if (server == null || rule == null) {
        counts['activeAlertsSkipped'] = (counts['activeAlertsSkipped'] ?? 0) + 1;
        continue;
      }
      await repository.insertRestoredAlert({...raw, 'serverId': server, 'ruleId': rule});
      counts['activeAlerts'] = (counts['activeAlerts'] ?? 0) + 1;
    }

    for (final raw in _list(document, 'alertHistory')) {
      final mapped = remapServerId(raw['serverId'] as int? ?? 0, serverIdMap);
      if (mapped == null) {
        counts['alertHistorySkipped'] = (counts['alertHistorySkipped'] ?? 0) + 1;
        continue;
      }
      await repository.insertRestoredAlertHistory({...raw, 'serverId': mapped});
      counts['alertHistory'] = (counts['alertHistory'] ?? 0) + 1;
    }

    for (final raw in _list(document, 'networkShares')) {
      // Shares reference no host, so there is nothing to remap and nothing to skip.
      await repository.insertRestoredShare(raw);
      counts['networkShares'] = (counts['networkShares'] ?? 0) + 1;
    }

    for (final raw in _list(document, 'wolTargets')) {
      await repository.insertRestoredWolTarget(raw);
      counts['wolTargets'] = (counts['wolTargets'] ?? 0) + 1;
    }

    for (final raw in _list(document, 'settings')) {
      final key = raw['key'] as String?;
      if (key == null || key == 'app_pin') continue;
      await repository.insertRestoredSetting(key, raw['value'] as String? ?? '');
      counts['settings'] = (counts['settings'] ?? 0) + 1;
    }

    return counts;
  }

  static List<Map<String, dynamic>> _list(Map<String, dynamic> document, String key) {
    final value = document[key];
    if (value is! List) return const [];
    return [
      for (final entry in value)
        if (entry is Map<String, dynamic>) entry,
    ];
  }
}

/// The repository operations a restore needs.
///
/// Narrow on purpose: a restore writes rows and nothing else, and this keeps the payload logic
/// testable without a database while making the write surface obvious at a glance.
abstract interface class AppRepositoryLike {
  Future<int> insertRestoredServer(Map<String, dynamic> row);
  Future<void> insertRestoredKey(Map<String, dynamic> row);
  Future<void> insertRestoredProfile(Map<String, dynamic> row);
  Future<void> insertRestoredScript(Map<String, dynamic> row);

  /// Returns the new row id, so a firing alert can be re-pointed at the rule that raised it.
  Future<int> insertRestoredRule(Map<String, dynamic> row);
  Future<void> insertRestoredAlert(Map<String, dynamic> row);
  Future<void> insertRestoredAlertHistory(Map<String, dynamic> row);
  Future<void> insertRestoredShare(Map<String, dynamic> row);
  Future<void> insertRestoredWolTarget(Map<String, dynamic> row);
  Future<void> insertRestoredPortForward(Map<String, dynamic> row);
  Future<void> insertRestoredSetting(String key, String value);
}

/// Writes restored rows through the real repository.
class RepositoryRestoreTarget implements AppRepositoryLike {
  const RepositoryRestoreTarget(this._repository);

  final AppRepository _repository;

  @override
  Future<int> insertRestoredServer(Map<String, dynamic> row) => _repository.insertServer(
    Server(
      id: 0,
      name: row['name'] as String? ?? 'Restored host',
      host: row['host'] as String? ?? '',
      port: row['port'] as int? ?? 22,
      username: row['username'] as String? ?? '',
      groupName: row['groupName'] as String?,
      serverColor: row['serverColor'] as String? ?? 'Default',
      authType: row['authType'] as String? ?? 'password',
      authKeyAlias: row['authKeyAlias'] as String?,
      authPassword: row['authPassword'] as String?,
      sudoPassword: row['sudoPassword'] as String? ?? '',
      authProfileId: row['authProfileId'] as int?,
      notes: row['notes'] as String? ?? '',
      keepAlive: row['keepAlive'] as int? ?? 30,
      sshCompression: row['sshCompression'] as bool? ?? false,
      persistentSession: row['persistentSession'] as bool? ?? false,
      proxyCommand: '',
      proxyType: row['proxyType'] as String? ?? 'none',
      proxyHost: row['proxyHost'] as String? ?? '',
      proxyPort: row['proxyPort'] as int? ?? 0,
      proxyUser: row['proxyUser'] as String? ?? '',
      proxyPassword: row['proxyPassword'] as String? ?? '',
      proxyKeyAlias: row['proxyKeyAlias'] as String?,
      agentForwarding: row['agentForwarding'] as bool? ?? false,
      // A restored host has not been probed yet; carrying its old score would show a health
      // figure for a connection that has never been made on this device.
      healthScore: 100,
      lastLatency: 0,
      status: 'offline',
      authStatus: 'unknown',
    ),
  );

  @override
  Future<void> insertRestoredKey(Map<String, dynamic> row) => _repository.insertKey(
    SshKey(
      id: 0,
      alias: row['alias'] as String? ?? 'restored',
      keyType: row['keyType'] as String? ?? 'SSH Key',
      privateKey: row['privateKey'] as String? ?? '',
      publicKey: row['publicKey'] as String? ?? '',
      fingerprint: row['fingerprint'] as String? ?? '',
    ),
  );

  @override
  Future<void> insertRestoredProfile(Map<String, dynamic> row) => _repository.insertProfile(
    CredentialProfile(
      id: 0,
      profileName: row['profileName'] as String? ?? 'Restored profile',
      username: row['username'] as String? ?? '',
      authType: row['authType'] as String? ?? 'password',
      password: row['password'] as String?,
      keyAlias: row['keyAlias'] as String?,
      groupName: row['groupName'] as String? ?? 'General',
    ),
  );

  @override
  Future<void> insertRestoredScript(Map<String, dynamic> row) => _repository.insertScript(
    QuickScriptsCompanion.insert(
      emoji: row['emoji'] as String? ?? '»',
      name: row['name'] as String? ?? 'Restored script',
      command: row['command'] as String? ?? '',
      color: row['color'] as String? ?? 'cyan',
      longRunning: Value(row['longRunning'] as bool? ?? false),
      category: Value(row['category'] as String? ?? 'General'),
      sortOrder: Value(row['sortOrder'] as int? ?? 0),
      availableForQuick: Value(row['availableForQuick'] as bool? ?? true),
      availableForFleet: Value(row['availableForFleet'] as bool? ?? false),
      targetOs: Value(row['targetOs'] as String? ?? 'Any'),
      targetSystem: Value(row['targetSystem'] as String? ?? 'Any'),
      notes: Value(row['notes'] as String? ?? ''),
      presetKey: Value(row['presetKey'] as String?),
    ),
  );

  @override
  Future<int> insertRestoredRule(Map<String, dynamic> row) => _repository.insertRule(
    AlertRulesCompanion.insert(
      serverId: row['serverId'] as int? ?? 0,
      metricName: row['metricName'] as String? ?? 'CPU Usage',
      mountPoint: Value(row['mountPoint'] as String? ?? '/'),
      thresholdValue: (row['thresholdValue'] as num?)?.toDouble() ?? 90,
      severity: row['severity'] as String? ?? 'WARNING',
      triggerWindow: Value(row['triggerWindow'] as String? ?? '5m'),
      enabled: Value(row['enabled'] as bool? ?? true),
      notes: Value(row['notes'] as String? ?? ''),
      presetKey: Value(row['presetKey'] as String?),
    ),
  );

  @override
  Future<void> insertRestoredAlert(Map<String, dynamic> row) async {
    await _repository.insertAlert(
      ActiveAlertsCompanion.insert(
        ruleId: row['ruleId'] as int? ?? 0,
        serverId: row['serverId'] as int? ?? 0,
        metricName: row['metricName'] as String? ?? '',
        currentValue: (row['currentValue'] as num?)?.toDouble() ?? 0,
        thresholdValue: (row['thresholdValue'] as num?)?.toDouble() ?? 0,
        severity: row['severity'] as String? ?? 'WARNING',
        triggeredTime: row['triggeredTime'] as int? ?? 0,
        acknowledged: Value(row['acknowledged'] as bool? ?? false),
        mutedUntil: Value(row['mutedUntil'] as int? ?? 0),
      ),
    );
  }

  @override
  Future<void> insertRestoredAlertHistory(Map<String, dynamic> row) async {
    await _repository.insertAlertHistory(
      AlertHistoryCompanion.insert(
        // The incident's own id from the source device. It is only an identity for the unique index
        // and never dereferenced, so it does not need remapping — but two backups restored onto one
        // device could collide, which the DAO's conflict handling absorbs.
        activeAlertId: row['activeAlertId'] as int? ?? 0,
        serverId: row['serverId'] as int? ?? 0,
        serverName: row['serverName'] as String? ?? '',
        metricName: row['metricName'] as String? ?? '',
        currentValue: (row['currentValue'] as num?)?.toDouble() ?? 0,
        thresholdValue: (row['thresholdValue'] as num?)?.toDouble() ?? 0,
        severity: row['severity'] as String? ?? 'WARNING',
        triggeredTime: row['triggeredTime'] as int? ?? 0,
        historyTime: row['historyTime'] as int? ?? 0,
        status: row['status'] as String? ?? 'RESOLVED',
      ),
    );
  }

  @override
  Future<void> insertRestoredShare(Map<String, dynamic> row) async {
    await _repository.insertNetworkShare(
      NetworkShare(
        id: 0,
        name: row['name'] as String? ?? 'Restored share',
        protocol: row['protocol'] as String? ?? 'SMB',
        address: row['address'] as String? ?? '',
        port: row['port'] as int? ?? 445,
        sharePath: row['sharePath'] as String? ?? '',
        workgroup: row['workgroup'] as String? ?? '',
        username: row['username'] as String? ?? '',
        password: row['password'] as String? ?? '',
        authProfileId: row['authProfileId'] as int?,
        anonymous: row['anonymous'] as bool? ?? true,
        useHttps: row['useHttps'] as bool? ?? false,
        notes: row['notes'] as String? ?? '',
        // Reachability is this device's observation, not the backup's: a share that answered on the
        // old phone says nothing about this one, and restoring "online" would show a green dot for
        // a check that never ran here.
        lastChecked: 0,
        lastStatus: '',
      ),
    );
  }

  @override
  Future<void> insertRestoredWolTarget(Map<String, dynamic> row) => _repository.insertWolTarget(
    WolTargetsCompanion.insert(
      name: row['name'] as String? ?? 'Restored target',
      macAddress: row['macAddress'] as String? ?? '',
      broadcastIp: Value(row['broadcastIp'] as String? ?? '255.255.255.255'),
      ipAddress: Value(row['ipAddress'] as String? ?? ''),
      port: Value(row['port'] as int? ?? 9),
    ),
  );

  @override
  Future<void> insertRestoredPortForward(Map<String, dynamic> row) => _repository.insertPortForward(
    PortForwardsCompanion.insert(
      serverId: row['serverId'] as int? ?? 0,
      name: row['name'] as String? ?? 'Restored tunnel',
      kind: Value(row['kind'] as String? ?? 'local'),
      bindHost: Value(row['bindHost'] as String? ?? '127.0.0.1'),
      bindPort: row['bindPort'] as int? ?? 0,
      destHost: Value(row['destHost'] as String? ?? ''),
      destPort: Value(row['destPort'] as int? ?? 0),
      // Deliberately **not** restored as auto-start. A backup carried to a new device would
      // otherwise open ports on it at first launch, before its owner had seen the tunnel exists.
      autoStart: const Value(false),
    ),
  );

  @override
  Future<void> insertRestoredSetting(String key, String value) =>
      _repository.insertSetting(key, value);
}
