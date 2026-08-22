import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../data/ssh/secure_host_key_store.dart';
import '../../data/ssh/ssh_host_key_trust.dart';
import '../../data/backup/backup_envelope.dart';
import '../../data/backup/backup_payload.dart';
import '../../domain/backup_selection.dart';
import 'app_state.dart';
import '../../platform/crash_log.dart';

@immutable
class BackupHostOption {
  const BackupHostOption({required this.oldId, required this.name, required this.host});

  final int oldId;
  final String name;
  final String host;
}

@immutable
class BackupInspection {
  const BackupInspection({
    required this.plainJson,
    required this.available,
    required this.counts,
    required this.hosts,
  });

  final String plainJson;
  final BackupSelection available;
  final Map<BackupSection, int> counts;
  final List<BackupHostOption> hosts;
}

/// The Backup tool's state and actions, split out of `BackupToolView` in `ui/ToolsScreen.kt`.
///
/// This class produces and consumes the backup *text*; the screen hands it to the platform's
/// document picker. Keeping the two apart is what lets the whole export/restore path be tested
/// without a file dialog, and it is why the reporting helpers below exist — the outcome of writing
/// the file is something only the caller knows.
class BackupViewModel extends ChangeNotifier {
  BackupViewModel(this._app, {CrashLog? crashLog, SshHostKeyTrust? hostKeyTrust})
    : crashLog = crashLog ?? CrashLog.instance,
      hostKeyTrust = hostKeyTrust ?? SshHostKeyTrust(SecureHostKeyStore());

  final AppState _app;
  final CrashLog crashLog;

  /// Pinned host keys, which travel with the hosts in a backup.
  final SshHostKeyTrust hostKeyTrust;

  /// Pinned host keys for the export, or none if the trust store cannot be read.
  ///
  /// A locked or unavailable keystore must not cost the user their whole backup — every other
  /// section is still worth writing. The restore side already tolerates the key being absent.
  Future<Map<String, String>> _pinnedHostKeys() async {
    try {
      return await hostKeyTrust.exportEntries();
    } catch (_) {
      return const {};
    }
  }

  bool _disposed = false;

  void _safeNotify() {
    if (!_disposed) notifyListeners();
  }

  BackupSelection _selection = BackupSelection.all();

  BackupSelection get selection => _selection;

  void toggleSection(BackupSection section, {required bool enabled}) {
    _selection = _selection.toggled(section, enabled: enabled);
    _persistSelection();
    notifyListeners();
  }

  void selectAll() {
    _selection = BackupSelection.all(includeCrashLogs: true);
    _persistSelection();
    notifyListeners();
  }

  void selectNone() {
    _selection = const BackupSelection.none();
    _persistSelection();
    notifyListeners();
  }

  /// Remembers what the user chose to back up.
  ///
  /// Ported from Kotlin's `updateBackupExportSelection` (`AppViewModel.kt:2310`). Without it every
  /// visit to this screen starts from "everything", so a user who deliberately excludes crash logs
  /// or alert history has to exclude them again every single time.
  ///
  /// Fire-and-forget, as Kotlin does: the checkbox has already moved, and the write must not make
  /// the UI wait on the database.
  void _persistSelection() {
    unawaited(_app.repository.insertSetting('backup_export_selection', _selection.encode()));
  }

  /// Reads the stored selection back. Safe to call more than once.
  Future<void> loadSelection() async {
    if (_selectionLoaded) return;
    _selectionLoaded = true;
    final stored = await _app.repository.getSetting('backup_export_selection');
    if (_disposed || stored == null || stored.trim().isEmpty) return;
    _selection = BackupSelection.decode(stored);
    _safeNotify();
  }

  bool _selectionLoaded = false;

  /// True when the current selection would carry credentials or host identities.
  ///
  /// Drives the requirement to encrypt: an unencrypted export of this would put every stored
  /// password into a file the user may well drop in a cloud drive.
  bool get requiresPassphrase => _selection.hasSensitiveData;

  /// The shortest passphrase a sensitive backup may be encrypted with.
  ///
  /// Kotlin refuses anything shorter (`ui/AppViewModel.kt:11361`), and this is the same number so
  /// a backup made on one app opens on the other. It lives here, next to the check that enforces
  /// it, because the previous arrangement is what broke: Kotlin's dialog advertised eight, gated
  /// its own button on eight, and the export then refused twelve — with the file already created.
  static const passphraseMinLength = 12;

  bool get canExport => !_selection.isEmpty && !_busy;

  bool _busy = false;
  String? _error;
  String? _status;

  bool get busy => _busy;
  String? get error => _error;
  String? get status => _status;

  void dismissMessages() {
    _error = null;
    _status = null;
    notifyListeners();
  }

  // ── export ──────────────────────────────────────────────────────────────────

  /// Builds the backup file's contents, or null when it could not be produced.
  ///
  /// The passphrase is required whenever the selection is sensitive — this is not a preference the
  /// caller can skip, because the alternative is every stored secret in plain text on disk.
  Future<String?> exportBackup(String passphrase) async {
    if (_selection.isEmpty) {
      _error = 'Choose at least one thing to back up.';
      _safeNotify();
      return null;
    }
    if (requiresPassphrase && passphrase.isEmpty) {
      _error = 'This backup contains credentials, so it needs a passphrase.';
      _safeNotify();
      return null;
    }
    if (requiresPassphrase && passphrase.length < passphraseMinLength) {
      // Enforced here as well as in the dialog: this is the boundary that decides whether
      // credentials get encrypted weakly, and it must not depend on which screen called it.
      _error =
          'The passphrase must be at least $passphraseMinLength characters, '
          'because it is the only thing protecting the credentials in this file.';
      _safeNotify();
      return null;
    }

    _busy = true;
    _error = null;
    _safeNotify();

    try {
      final repository = _app.repository;
      final json = BackupPayload.encode(
        selection: _selection,
        servers: await repository.getAllServers(),
        keys: await repository.getAllKeys(),
        profiles: await repository.getAllProfiles(),
        scripts: await repository.getAllScripts(),
        rules: await repository.getAllRules(),
        wolTargets: await repository.getAllWolTargets(),
        portForwards: await repository.getAllPortForwards(),
        settings: await repository.getAllSettings(),
        activeAlerts: await repository.getActiveAlerts(),
        alertHistory: await repository.getAlertHistory(),
        networkShares: await repository.getAllNetworkShares(),
        crashLogs: crashLog.entries,
        knownHosts: await _pinnedHostKeys(),
      );

      // An unencrypted export is only reachable for a selection with nothing sensitive in it.
      // No status here on purpose. The export is only half the job now that the file dialog
      // follows it, and "Backup ready." left standing after a cancelled save would claim a file
      // that was never written. The save reports the real outcome.
      return passphrase.isEmpty ? json : await encryptBackup(json, passphrase);
    } on BackupException catch (e) {
      _error = e.message;
      return null;
    } catch (e) {
      _error = 'Could not build the backup: $e';
      return null;
    } finally {
      _busy = false;
      _safeNotify();
    }
  }

  /// A default file name, dated so successive backups do not overwrite each other.
  String suggestedFileName() {
    final now = DateTime.now();
    String two(int value) => value.toString().padLeft(2, '0');
    return 'omniterm-${now.year}${two(now.month)}${two(now.day)}-'
        '${two(now.hour)}${two(now.minute)}.omnibak';
  }

  /// When a backup was last written, or null if never.
  ///
  /// Ported from Kotlin's `lastBackupExportTime` (`AppViewModel.kt:1052`, shown on the Backup screen
  /// at `ToolsScreen.kt:2691`). The value of showing it is entirely in the "Never" case: a user who
  /// believes they have a backup and does not is the one this screen exists for.
  DateTime? get lastExportTime => _lastExportTime;
  DateTime? _lastExportTime;

  /// Reads the recorded time. Safe to call more than once.
  Future<void> loadLastExportTime() async {
    final stored = await _app.repository.getSetting('backup_last_export_time');
    final ms = int.tryParse(stored?.trim() ?? '');
    if (_disposed || ms == null || ms <= 0) return;
    _lastExportTime = DateTime.fromMillisecondsSinceEpoch(ms);
    _safeNotify();
  }

  /// Report a completed save.
  ///
  /// The location is named rather than a bare "done": a backup the user cannot find is one they
  /// will assume did not happen. The passphrase reminder is repeated here, at the moment the file
  /// becomes a real, portable thing that can be lost — which is when it matters, not when the
  /// passphrase was chosen.
  void reportSaved(String? location, {required bool encrypted}) {
    // Recorded here rather than when the JSON was built: the file dialog can still be cancelled, and
    // a "last backup" that counts an export the user abandoned is worse than none at all. Kotlin
    // records it on write success too (`AppViewModel.kt:11415`).
    final now = DateTime.now();
    _lastExportTime = now;
    unawaited(
      _app.repository.insertSetting('backup_last_export_time', '${now.millisecondsSinceEpoch}'),
    );
    _error = null;
    _status = [
      location == null ? 'Backup saved.' : 'Backup saved to $location',
      if (encrypted)
        'It is encrypted with the passphrase you chose. Without that passphrase it cannot be '
            'opened, and nobody can reset it.'
      else
        'It is not encrypted, because nothing sensitive was selected. Anyone who opens the file can '
            'read it.',
    ].join(' ');
    _safeNotify();
  }

  void reportSaveFailed(String? error) {
    _status = null;
    _error = error ?? 'The file could not be saved.';
    _safeNotify();
  }

  // ── import ──────────────────────────────────────────────────────────────────

  /// True when [contents] looks like an encrypted envelope rather than plain JSON.
  ///
  /// Lets the UI ask for a passphrase only when one is needed, instead of demanding one for a file
  /// that does not have any.
  static bool looksEncrypted(String contents) {
    final trimmed = contents.trimLeft();
    return trimmed.startsWith('{') && trimmed.contains('"iv"') && trimmed.contains('"salt"');
  }

  static const _sectionKeys = <BackupSection, String>{
    BackupSection.servers: 'servers',
    BackupSection.sshKeys: 'sshKeys',
    BackupSection.credentialProfiles: 'credentialProfiles',
    BackupSection.scripts: 'scripts',
    BackupSection.alertRules: 'alertRules',
    BackupSection.activeAlerts: 'activeAlerts',
    BackupSection.alertHistory: 'alertHistory',
    BackupSection.wolTargets: 'wolTargets',
    BackupSection.networkShares: 'networkShares',
    BackupSection.portForwards: 'portForwards',
    BackupSection.settings: 'settings',
    BackupSection.crashLogs: 'crashLogs',
  };

  /// Decrypts and inventories a backup without writing anything.
  ///
  /// Restore is deliberately two-phase, matching the native app: the user first sees exactly what
  /// the file contains and chooses sections/hosts, then confirms the additive write.
  Future<BackupInspection?> inspectBackup(String contents, String passphrase) async {
    _busy = true;
    _error = null;
    _status = null;
    _safeNotify();
    try {
      final json = looksEncrypted(contents) ? await decryptBackup(contents, passphrase) : contents;
      final decoded = jsonDecode(json);
      if (decoded is! Map<String, dynamic>) {
        throw const BackupException('That backup file could not be read.');
      }
      // Checked before anything is parsed out of it: refusing a file whole is honest, whereas
      // reading half of an unfamiliar shape and restoring that is not.
      final incompatible = BackupPayload.incompatibleVersionMessage(decoded['v']);
      if (incompatible != null) throw BackupException(incompatible);
      final counts = <BackupSection, int>{};
      final present = <BackupSection>{};
      for (final entry in _sectionKeys.entries) {
        final value = decoded[entry.value];
        final count = value is List ? value.length : 0;
        counts[entry.key] = count;
        if (count > 0) present.add(entry.key);
      }
      if (present.isEmpty) {
        throw const BackupException('That backup contains no data OmniTerm can restore.');
      }
      final hosts = <BackupHostOption>[];
      final rawHosts = decoded['servers'];
      if (rawHosts is List) {
        for (final value in rawHosts) {
          if (value is! Map<String, dynamic>) continue;
          final oldId = (value['id'] as num?)?.toInt() ?? 0;
          if (oldId <= 0) continue;
          hosts.add(
            BackupHostOption(
              oldId: oldId,
              name: value['name'] as String? ?? 'Restored host',
              host: value['host'] as String? ?? '',
            ),
          );
        }
      }
      return BackupInspection(
        plainJson: json,
        available: BackupSelection(present).withReferentialClosure(),
        counts: Map.unmodifiable(counts),
        hosts: List.unmodifiable(hosts),
      );
    } on BackupException catch (e) {
      _error = e.message;
      return null;
    } catch (e) {
      _error = 'Could not inspect that backup: $e';
      return null;
    } finally {
      _busy = false;
      _safeNotify();
    }
  }

  /// Restores [contents] into the database.
  ///
  /// **Additive:** existing rows are kept and the backup's rows are added alongside them. Wiping
  /// first would make restoring the wrong file unrecoverable, and there is no undo for that. The UI
  /// says so before running.
  Future<Map<String, int>?> importBackup(
    String contents,
    String passphrase, {
    BackupSelection? selection,
    Set<int>? selectedServerIds,
  }) async {
    _busy = true;
    _error = null;
    _status = null;
    _safeNotify();

    try {
      var json = looksEncrypted(contents) ? await decryptBackup(contents, passphrase) : contents;

      if (selection != null || selectedServerIds != null) {
        final root = jsonDecode(json) as Map<String, dynamic>;
        final chosen = selection ?? BackupSelection.all(includeCrashLogs: true);
        final closed = chosen.withReferentialClosure();
        for (final entry in _sectionKeys.entries) {
          if (!closed.contains(entry.key)) root.remove(entry.value);
        }
        if (selectedServerIds != null && root['servers'] is List) {
          final ids = selectedServerIds;
          root['servers'] = [
            for (final value in root['servers'] as List)
              if (value is Map<String, dynamic> && ids.contains((value['id'] as num?)?.toInt()))
                value,
          ];
          bool belongsToChosenHost(Object? value) {
            if (value is! Map<String, dynamic>) return false;
            final id = (value['serverId'] as num?)?.toInt() ?? 0;
            return id == 0 || ids.contains(id);
          }

          for (final key in const ['alertRules', 'activeAlerts', 'alertHistory', 'portForwards']) {
            if (root[key] is List) {
              root[key] = (root[key] as List).where(belongsToChosenHost).toList();
            }
          }
        }

        // Match the native restore's least-secret behavior: when endpoints are part of a selective
        // restore, only the profiles and keys those chosen endpoints actually reference travel with
        // them. This also guarantees that a deselected host cannot leave an unused credential behind.
        if (root['servers'] is List || root['networkShares'] is List) {
          Iterable<Map<String, dynamic>> rows(String key) sync* {
            final value = root[key];
            if (value is! List) return;
            for (final row in value) {
              if (row is Map<String, dynamic>) yield row;
            }
          }

          final profileIds = <int>{
            for (final row in [...rows('servers'), ...rows('networkShares')])
              if ((row['authProfileId'] as num?)?.toInt() case final int id when id != 0) id,
          };
          if (root['credentialProfiles'] is List) {
            root['credentialProfiles'] = rows(
              'credentialProfiles',
            ).where((row) => profileIds.contains((row['id'] as num?)?.toInt())).toList();
          }

          final keyAliases = <String>{
            for (final row in rows('servers'))
              for (final field in const ['authKeyAlias', 'proxyKeyAlias'])
                if ((row[field] as String?)?.trim() case final String alias when alias.isNotEmpty)
                  alias,
            for (final row in rows('credentialProfiles'))
              if ((row['keyAlias'] as String?)?.trim() case final String alias
                  when alias.isNotEmpty)
                alias,
          };
          if (root['sshKeys'] is List) {
            root['sshKeys'] = rows(
              'sshKeys',
            ).where((row) => keyAliases.contains(row['alias'])).toList();
          }
        }
        json = jsonEncode(root);
      }

      // Every database row is one restore operation. A malformed later section must roll the
      // earlier sections back, otherwise the UI reports failure after silently leaving half a
      // backup behind. Crash logs live outside Drift and are merged only after this commits.
      final counts = await _app.repository.inTransaction(
        () => BackupPayload.restore(RepositoryRestoreTarget(_app.repository), json),
      );
      final root = jsonDecode(json) as Map<String, Object?>;

      // Pinned host keys, imported only for hosts that were actually restored. A limited restore
      // skips hosts, and importing their keys anyway would leave orphaned trust entries — a pin for
      // a host this device does not have, which would silently auto-trust it if it were re-added
      // later. `filterEntriesForHosts` is the rule Compose applies at `ui/AppViewModel.kt:11650`;
      // it was ported and tested here and had no caller until now.
      if (root['knownHosts'] case final Map<Object?, Object?> pinned when pinned.isNotEmpty) {
        final entries = <String, String>{
          for (final entry in pinned.entries)
            if (entry.key case final String alias)
              if (entry.value case final String fingerprint) alias: fingerprint,
        };
        final hosts = <(String, int)>[
          for (final row in (root['servers'] as List<Object?>? ?? const []))
            if (row case {'host': final String host}) (host, (row['port'] as num?)?.toInt() ?? 22),
        ];
        final kept = SshHostKeyTrust.filterEntriesForHosts(entries, hosts);
        if (kept.isNotEmpty) await hostKeyTrust.importEntries(kept);
        counts['knownHosts'] = kept.length;
        if (entries.length > kept.length) {
          counts['knownHostsSkipped'] = entries.length - kept.length;
        }
      }

      final restoredCrashes = <CrashEntry>[];
      for (final value in (root['crashLogs'] as List<Object?>? ?? const [])) {
        if (value case {'t': final num time, 'r': final String report}) {
          restoredCrashes.add(CrashEntry(timeMs: time.toInt(), report: redactCrashReport(report)));
        }
      }
      if (restoredCrashes.isNotEmpty) {
        counts['crashLogs'] = await crashLog.merge(restoredCrashes);
      }

      // A backup can carry far more archived incidents than this device is configured to keep, and
      // the per-host prune only runs when a host archives something. Without this the restored
      // excess would sit there indefinitely. Kotlin prunes here too (`AppViewModel.kt:11804`).
      if ((counts['alertHistory'] ?? 0) > 0) {
        await _app.repository.pruneAlertHistoryPerServer(_app.alertHistoryLimit);
      }

      final restored = counts.entries
          .where((e) => !e.key.endsWith('Skipped'))
          .fold<int>(0, (sum, e) => sum + e.value);
      // Naming every skip rather than hiding it: a rule silently missing after a restore is a rule
      // no longer watching anything, and a missing tunnel is a port that never opens.
      final skips = <String>[
        if ((counts['alertRulesSkipped'] ?? 0) > 0) '${counts['alertRulesSkipped']} alert rule(s)',
        if ((counts['portForwardsSkipped'] ?? 0) > 0) '${counts['portForwardsSkipped']} tunnel(s)',
        if ((counts['activeAlertsSkipped'] ?? 0) > 0)
          '${counts['activeAlertsSkipped']} firing alert(s)',
        if ((counts['alertHistorySkipped'] ?? 0) > 0)
          '${counts['alertHistorySkipped']} alert history row(s)',
      ];

      _status = skips.isEmpty
          ? 'Restored $restored items.'
          : 'Restored $restored items. ${skips.join(' and ')} were skipped because the hosts they '
                'belong to were not in this backup.';
      return counts;
    } on BackupException catch (e) {
      _error = e.message;
      return null;
    } catch (e) {
      _error = 'Could not restore that backup: $e';
      return null;
    } finally {
      _busy = false;
      _safeNotify();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
