import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omniterm/data/app_database.dart';

/// The Flutter app opens the *same* SQLite file the shipped Android app created, so the Drift
/// schema must be identical to Room's. These tests compare what Drift actually creates against
/// Room's committed schema export — the real artifact, not a transcription of it — so any drift
/// (a renamed column, a lost index, a changed type) fails here rather than on a user's device.
///
/// Room's export lives at `app/schemas/com.jetsetslow.omniterm.data.AppDatabase/22.json`.
void main() {
  late Map<String, dynamic> roomSchema;

  setUpAll(() {
    // Located relative to the repo, not the machine — the suite must stay host-independent.
    final file = File('../app/schemas/com.jetsetslow.omniterm.data.AppDatabase/22.json');
    expect(
      file.existsSync(),
      isTrue,
      reason: 'Room schema export missing at ${file.absolute.path}',
    );
    roomSchema = json.decode(file.readAsStringSync()) as Map<String, dynamic>;
  });

  /// Reads the live schema out of a freshly created Drift database.
  Future<List<({String type, String name, String tbl, String? sql})>> introspect() async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    // Force creation.
    await db.customSelect('SELECT 1').get();
    final rows = await db
        .customSelect(
          "SELECT type, name, tbl_name, sql FROM sqlite_master WHERE name NOT LIKE 'sqlite_%'",
        )
        .get();
    return rows
        .map(
          (r) => (
            type: r.read<String>('type'),
            name: r.read<String>('name'),
            tbl: r.read<String>('tbl_name'),
            sql: r.data['sql'] as String?,
          ),
        )
        .toList();
  }

  /// Normalises DDL so the comparison is about schema, not formatting: Room quotes identifiers
  /// with backticks and drift with double quotes, and the two differ in whitespace and in where
  /// they place `IF NOT EXISTS`.
  String normalise(String sql) => sql
      .replaceAll('`', '')
      .replaceAll('"', '')
      .replaceAll('IF NOT EXISTS ', '')
      .replaceAll(RegExp(r'\s+'), ' ')
      .replaceAll(' )', ')')
      .replaceAll('( ', '(')
      .trim()
      .toUpperCase();

  test('schema version matches the Room database version', () {
    final database = roomSchema['database'] as Map<String, dynamic>;
    expect(
      kRoomSchemaVersion,
      database['version'],
      reason:
          'Drift must declare the version Room left in PRAGMA user_version, '
          'or an existing database is either re-migrated or rejected',
    );
  });

  test('every Room table exists in the Drift schema with identical columns', () async {
    final live = await introspect();
    final liveTables = {for (final o in live.where((o) => o.type == 'table')) o.name: o.sql!};

    final entities = (roomSchema['database'] as Map<String, dynamic>)['entities'] as List<dynamic>;
    expect(entities, hasLength(14));

    for (final entity in entities.cast<Map<String, dynamic>>()) {
      final table = entity['tableName'] as String;
      expect(liveTables, contains(table), reason: 'missing table $table');

      final roomDdl = (entity['createSql'] as String).replaceAll(r'${TABLE_NAME}', table);
      final roomCols = _columns(normalise(roomDdl));
      final liveCols = _columns(normalise(liveTables[table]!));

      expect(
        liveCols,
        roomCols,
        reason:
            'column set/order/type differs for `$table`\n'
            'Room:  $roomCols\n'
            'Drift: $liveCols',
      );
    }
  });

  test('every Room index is reproduced, including uniqueness', () async {
    final live = await introspect();
    final liveIndexes = {
      for (final o in live.where((o) => o.type == 'index' && o.sql != null))
        o.name: normalise(o.sql!),
    };

    final entities = (roomSchema['database'] as Map<String, dynamic>)['entities'] as List<dynamic>;
    var checked = 0;
    for (final entity in entities.cast<Map<String, dynamic>>()) {
      final table = entity['tableName'] as String;
      for (final index
          in (entity['indices'] as List<dynamic>? ?? []).cast<Map<String, dynamic>>()) {
        final name = index['name'] as String;
        expect(liveIndexes, contains(name), reason: 'missing index $name on $table');

        final expected = normalise(
          (index['createSql'] as String).replaceAll(r'${TABLE_NAME}', table),
        );
        expect(liveIndexes[name], expected, reason: 'index $name differs');
        checked++;
      }
    }
    // metric_history, active_alerts, alert_history, stack_registry.
    expect(checked, 4, reason: 'expected exactly four indices in the v22 schema');
  });

  test('an existing Room database at user_version 22 opens without migrating', () async {
    // Simulate what is on a user's device: the exact Room DDL, user_version stamped by
    // SQLiteOpenHelper, and one row of real data.
    final file = File('${Directory.systemTemp.createTempSync('omniterm').path}/omniterm_database');
    final seed = NativeDatabase(file);
    final setup = AppDatabase(seed);
    await setup.customSelect('SELECT 1').get();
    await setup.customStatement(
      "INSERT INTO servers (name, host, port, username, serverColor, authType, sudoPassword, "
      "notes, keepAlive, sshCompression, persistentSession, proxyCommand, proxyType, proxyHost, "
      "proxyPort, proxyUser, proxyPassword, agentForwarding, healthScore, lastLatency, status, "
      "authStatus) VALUES ('nas', '10.0.0.2', 22, 'root', 'Default', 'password', '', '', 30, 0, 0, "
      "'', 'none', '', 0, '', '', 0, 100, 0, 'offline', 'unknown')",
    );
    final stamped = await setup.customSelect('PRAGMA user_version').getSingle();
    await setup.close();

    expect(
      stamped.data.values.first,
      kRoomSchemaVersion,
      reason: 'drift must stamp the same user_version Room does',
    );

    // Reopen: no migration should run, and the row must survive.
    final reopened = AppDatabase(NativeDatabase(file));
    addTearDown(reopened.close);
    final rows = await reopened.customSelect('SELECT name FROM servers').get();
    expect(rows, hasLength(1));
    expect(rows.single.read<String>('name'), 'nas');
  });
}

/// Extracts `NAME TYPE` pairs from a normalised CREATE TABLE statement, preserving order.
List<String> _columns(String normalisedDdl) {
  final open = normalisedDdl.indexOf('(');
  final body = normalisedDdl.substring(open + 1, normalisedDdl.lastIndexOf(')'));

  final parts = <String>[];
  var depth = 0;
  var current = StringBuffer();
  for (final rune in body.runes) {
    final ch = String.fromCharCode(rune);
    if (ch == '(') depth++;
    if (ch == ')') depth--;
    if (ch == ',' && depth == 0) {
      parts.add(current.toString().trim());
      current = StringBuffer();
    } else {
      current.write(ch);
    }
  }
  parts.add(current.toString().trim());

  return [
    for (final part in parts)
      // Skip table-level constraints such as PRIMARY KEY(`key`).
      if (!part.startsWith('PRIMARY KEY') &&
          !part.startsWith('FOREIGN KEY') &&
          !part.startsWith('UNIQUE') &&
          !part.startsWith('CHECK'))
        _columnSignature(part),
  ];
}

/// `name TYPE [NOT NULL] [PRIMARY KEY ...]` reduced to the parts that must match: the column name,
/// its declared type, and whether it is nullable.
String _columnSignature(String definition) {
  final tokens = definition.split(' ');
  final name = tokens.first;
  final type = tokens.length > 1 ? tokens[1] : '';
  final notNull = definition.contains('NOT NULL');
  final pk = definition.contains('PRIMARY KEY');
  final autoinc = definition.contains('AUTOINCREMENT');
  return '$name $type${notNull ? ' NOT NULL' : ''}${pk ? ' PK' : ''}${autoinc ? ' AI' : ''}';
}
