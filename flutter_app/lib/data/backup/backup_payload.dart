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
/// Ids are exported for hosts and profiles only, because other rows reference them. Everything else
/// is restored with fresh ids — a backup is content, not a snapshot of a rowid space.
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
    required List<AppSetting> settings,
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

    for (final raw in _list(document, 'alertRules')) {
      final mapped = remapServerId(raw['serverId'] as int? ?? 0, serverIdMap);
      // A rule whose host was not in the backup has nothing to watch. Restoring it against an
      // arbitrary host would silently point it at the wrong machine.
      if (mapped == null) {
        counts['alertRulesSkipped'] = (counts['alertRulesSkipped'] ?? 0) + 1;
        continue;
      }
      await repository.insertRestoredRule({...raw, 'serverId': mapped});
      counts['alertRules'] = (counts['alertRules'] ?? 0) + 1;
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
  Future<void> insertRestoredRule(Map<String, dynamic> row);
  Future<void> insertRestoredWolTarget(Map<String, dynamic> row);
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
  Future<void> insertRestoredRule(Map<String, dynamic> row) => _repository.insertRule(
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
  Future<void> insertRestoredSetting(String key, String value) =>
      _repository.insertSetting(key, value);
}
