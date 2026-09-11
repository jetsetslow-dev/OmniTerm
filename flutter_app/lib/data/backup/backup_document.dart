import 'dart:convert';

import 'backup_envelope.dart';

/// Kotlin's published document schema. This is independent of the encrypted envelope's `v`.
const backupSchemaVersion = 5;

const backupSectionNames = [
  'servers',
  'sshKeys',
  'credentialProfiles',
  'scripts',
  'alertRules',
  'activeAlerts',
  'alertHistory',
  'wolTargets',
  'networkShares',
  'portForwards',
  'settings',
  'crashLogs',
];

/// Read both the published Kotlin format and the earlier Flutter v1/v2 documents into the
/// internal list-based representation used by inspection, selection and restore.
Map<String, dynamic> readBackupDocument(String text) {
  if (text.length > BackupLimits.maxPlainBytes) {
    throw const BackupException('That backup file is too large to open.');
  }
  validateBackupJsonDepth(text);
  final Object? decoded;
  try {
    decoded = jsonDecode(text.replaceFirst(RegExp(r'^\uFEFF'), ''));
  } on FormatException {
    throw const BackupException('That backup file could not be read.');
  }
  if (decoded is! Map<String, dynamic>) {
    throw const BackupException('That does not look like an OmniTerm backup.');
  }
  final root = Map<String, dynamic>.from(decoded);
  if (root.containsKey('format') || root.containsKey('schema')) {
    if (root['format'] != 'omniterm-backup') {
      throw const BackupException('That does not look like an OmniTerm backup.');
    }
    _checkVersion(root['schema'], backupSchemaVersion);
    if (root.containsKey('quickScripts')) root['scripts'] = root.remove('quickScripts');
    if (root['settings'] case final Map<String, dynamic> settings) {
      root['settings'] = [
        for (final entry in settings.entries) {'key': entry.key, 'value': entry.value},
      ];
    }
    root.remove('format');
    root.remove('schema');
    root['v'] = 2;
  } else {
    _checkVersion(root['v'] ?? 1, 2);
  }
  if (!backupSectionNames.any(root.containsKey)) {
    throw const BackupException('That backup contains no data OmniTerm can restore.');
  }
  for (final name in backupSectionNames) {
    if (!root.containsKey(name)) continue;
    final rows = root[name];
    if (rows is! List || rows.any((row) => row is! Map<String, dynamic>)) {
      throw BackupException('That backup contains an invalid $name section.');
    }
  }
  _validateValues(root);
  return root;
}

void _checkVersion(Object? value, int supported) {
  final version = value is int ? value : int.tryParse('$value');
  if (version == null || version < 1) {
    throw const BackupException('That backup has a missing or invalid format version.');
  }
  if (version > supported) {
    throw BackupException(
      'That backup was written by a newer version of OmniTerm (format $version; this build '
      'reads up to $supported). Update the app, then restore it.',
    );
  }
}

void _validateValues(Object? value) {
  if (value is Map) {
    if (value.length > 50000) throw const BackupException('Too many backup entries.');
    for (final entry in value.entries) {
      if ((entry.key as String).length > 256) {
        throw const BackupException('That backup contains an oversized field name.');
      }
      _validateValues(entry.value);
    }
  } else if (value is List) {
    if (value.length > 50000) throw const BackupException('Too many backup entries.');
    for (final entry in value) {
      _validateValues(entry);
    }
  } else if (value is String && value.length > 1024 * 1024) {
    throw const BackupException('That backup contains an oversized text field.');
  }
}

/// Export the schema the shipping Kotlin app already understands.
String writeBackupDocument(Map<String, dynamic> document) {
  final root = Map<String, dynamic>.from(document)..remove('v');
  root['format'] = 'omniterm-backup';
  root['schema'] = backupSchemaVersion;
  if (root.containsKey('scripts')) root['quickScripts'] = root.remove('scripts');
  if (root['settings'] case final List settings) {
    root['settings'] = {for (final row in settings) (row as Map)['key'] as String: row['value']};
  }
  return jsonEncode(root);
}
