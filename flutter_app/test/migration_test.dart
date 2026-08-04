import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omniterm/data/app_database.dart';
import 'package:sqlite3/sqlite3.dart' as raw_sqlite;

/// Exercises the Room migration chain ported into [AppDatabase].
///
/// It normally never runs — a device coming from the native app is already at v22 — but it is the
/// only path for a user who installs the Flutter build directly over an older native build. Each
/// starting point is built from Room's own committed schema export for that version, so the
/// fixtures are the real historical shapes rather than a guess at them.
void main() {
  const schemaDir = '../app/schemas/com.jetsetslow.omniterm.data.AppDatabase';

  Map<String, dynamic> loadSchema(int version) {
    final file = File('$schemaDir/$version.json');
    expect(file.existsSync(), isTrue, reason: 'missing schema export $version.json');
    return json.decode(file.readAsStringSync()) as Map<String, dynamic>;
  }

  /// Creates a database with the exact DDL Room used at [version], stamped with that
  /// `user_version` — i.e. what an old install actually looks like on disk.
  Future<File> seedLegacyDatabase(int version) async {
    final file = File(
      '${Directory.systemTemp.createTempSync('omniterm_v$version').path}/omniterm_database',
    );
    final raw = sqlite3Native(file);
    final entities =
        (loadSchema(version)['database'] as Map<String, dynamic>)['entities'] as List<dynamic>;
    for (final entity in entities.cast<Map<String, dynamic>>()) {
      final table = entity['tableName'] as String;
      raw.execute((entity['createSql'] as String).replaceAll(r'${TABLE_NAME}', table));
      for (final index
          in (entity['indices'] as List<dynamic>? ?? []).cast<Map<String, dynamic>>()) {
        raw.execute((index['createSql'] as String).replaceAll(r'${TABLE_NAME}', table));
      }
    }
    raw.execute('PRAGMA user_version = $version');
    raw.close();
    return file;
  }

  Future<Set<String>> tablesOf(AppDatabase db) async {
    final rows = await db
        .customSelect(
          "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'",
        )
        .get();
    return rows.map((r) => r.read<String>('name')).toSet();
  }

  Future<Set<String>> columnsOf(AppDatabase db, String table) async {
    final rows = await db.customSelect('PRAGMA table_info($table)').get();
    return rows.map((r) => r.read<String>('name')).toSet();
  }

  for (final from in const [8, 12, 18, 21]) {
    test('migrates a v$from database up to v$kRoomSchemaVersion', () async {
      final file = await seedLegacyDatabase(from);
      final db = AppDatabase(NativeDatabase(file));
      addTearDown(db.close);

      // Opening triggers the upgrade.
      final version = await db.customSelect('PRAGMA user_version').getSingle();
      expect(version.data.values.first, kRoomSchemaVersion);

      final tables = await tablesOf(db);
      expect(
        tables,
        containsAll(<String>{
          'servers',
          'metric_history',
          'ssh_keys',
          'credential_profiles',
          'alert_rules',
          'active_alerts',
          'alert_history',
          'quick_scripts',
          'wol_targets',
          'network_shares',
          'app_settings',
          'persistent_sessions',
          'port_forwards',
          'stack_registry',
        }),
      );

      // Columns each migration step was responsible for adding.
      expect(
        await columnsOf(db, 'servers'),
        containsAll(<String>{'proxyKeyAlias', 'persistentSession', 'agentForwarding'}),
      );
      expect(await columnsOf(db, 'quick_scripts'), containsAll(<String>{'notes', 'presetKey'}));
      expect(await columnsOf(db, 'alert_rules'), containsAll(<String>{'notes', 'presetKey'}));
      expect(await columnsOf(db, 'wol_targets'), contains('ipAddress'));
      expect(await columnsOf(db, 'network_shares'), contains('useHttps'));
      expect(await columnsOf(db, 'metric_history'), contains('cpuTemperatureC'));
      expect(await columnsOf(db, 'persistent_sessions'), contains('backgroundedAt'));

      // The backup-jobs table was dropped at 9 -> 10 and must not come back.
      expect(tables, isNot(contains('backup_jobs')));
    });
  }

  test('15 -> 16 backfills useHttps from the old port heuristic', () async {
    final file = await seedLegacyDatabase(15);
    final raw = sqlite3Native(file);
    // Two WebDAV shares: one on a TLS port, one plain; plus an SMB share that must be untouched.
    raw.execute(
      "INSERT INTO network_shares (name, protocol, address, port, sharePath, workgroup, username, "
      "password, anonymous, notes, lastChecked, lastStatus) VALUES "
      "('secure', 'WEBDAV', 'h', 443, '', '', '', '', 1, '', 0, 'unknown'),"
      "('plain', 'WEBDAV', 'h', 8080, '', '', '', '', 1, '', 0, 'unknown'),"
      "('alt', 'webdav', 'h', 8443, '', '', '', '', 1, '', 0, 'unknown'),"
      "('smb', 'SMB', 'h', 443, '', '', '', '', 1, '', 0, 'unknown')",
    );
    raw.close();

    final db = AppDatabase(NativeDatabase(file));
    addTearDown(db.close);
    final rows = await db
        .customSelect('SELECT name, useHttps FROM network_shares ORDER BY id')
        .get();
    final byName = {for (final r in rows) r.read<String>('name'): r.read<int>('useHttps')};

    expect(byName['secure'], 1, reason: '443 was treated as https before the flag existed');
    expect(byName['plain'], 0);
    expect(byName['alt'], 1, reason: 'protocol match is case-insensitive (UPPER(protocol))');
    expect(byName['smb'], 0, reason: 'only WebDAV shares are backfilled');
  });

  test('18 -> 19 keeps only the newest duplicate incident per (rule, host)', () async {
    final file = await seedLegacyDatabase(18);
    final raw = sqlite3Native(file);
    raw.execute(
      "INSERT INTO active_alerts (id, ruleId, serverId, metricName, currentValue, thresholdValue, "
      "severity, triggeredTime, acknowledged, mutedUntil) VALUES "
      "(1, 7, 3, 'CPU Usage', 91, 90, 'CRITICAL', 100, 0, 0),"
      "(2, 7, 3, 'CPU Usage', 95, 90, 'CRITICAL', 200, 0, 0),"
      "(3, 7, 4, 'CPU Usage', 92, 90, 'CRITICAL', 150, 0, 0)",
    );
    raw.close();

    final db = AppDatabase(NativeDatabase(file));
    addTearDown(db.close);
    final rows = await db.customSelect('SELECT id FROM active_alerts ORDER BY id').get();

    expect(
      rows.map((r) => r.read<int>('id')).toList(),
      [2, 3],
      reason: 'the older row for (rule 7, host 3) is dropped before the unique index is added',
    );
  });

  test('19 -> 20 seeds backgroundedAt from createdAt, not from now', () async {
    final file = await seedLegacyDatabase(19);
    final raw = sqlite3Native(file);
    raw.execute(
      "INSERT INTO persistent_sessions (tmuxName, serverId, serverName, createdAt) "
      "VALUES ('omni-1', 1, 'nas', 12345)",
    );
    raw.close();

    final db = AppDatabase(NativeDatabase(file));
    addTearDown(db.close);
    final row = await db.customSelect('SELECT backgroundedAt FROM persistent_sessions').getSingle();

    expect(
      row.read<int>('backgroundedAt'),
      12345,
      reason: 'seeding from "now" would falsely show every restored session as just-backgrounded',
    );
  });

  test('19 -> 20 only back-stamps presetKey when that preset family is enabled', () async {
    final file = await seedLegacyDatabase(19);
    final raw = sqlite3Native(file);
    raw.execute(
      "INSERT INTO quick_scripts (emoji, name, command, color, longRunning, category, sortOrder, "
      "availableForQuick, availableForFleet, targetOs, targetSystem, notes) VALUES "
      "('x', 'Disk usage', 'df -h', 'cyan', 0, 'Homelab', 0, 1, 0, 'Any', 'Any', '')",
    );
    // homelab_presets is explicitly disabled, so the matching row is NOT ours to claim.
    raw.execute("INSERT INTO app_settings (`key`, value) VALUES ('homelab_presets', 'false')");
    raw.close();

    final db = AppDatabase(NativeDatabase(file));
    addTearDown(db.close);
    final row = await db.customSelect('SELECT presetKey FROM quick_scripts').getSingle();

    expect(
      row.data['presetKey'],
      isNull,
      reason: 'a name/category match is not proof of ownership when the family was disabled',
    );
  });
}

/// Opens [file] with the raw sqlite3 API so fixtures can be written without going through drift
/// (which would create the *current* schema rather than the historical one under test).
raw_sqlite.Database sqlite3Native(File file) => raw_sqlite.sqlite3.open(file.path);
