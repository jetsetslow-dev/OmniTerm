import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../data/ssh/secure_host_key_store.dart';
import '../../data/ssh/ssh_host_key_trust.dart';
import '../../data/backup/backup_envelope.dart';
import '../../data/backup/backup_document.dart';
import '../../data/backup/backup_payload.dart';
import '../../domain/backup_selection.dart';
import 'app_state.dart';
import '../../platform/crash_log.dart';
import '../../platform/long_operation_notifications.dart';

// PBKDF2 and compression are CPU work. A Future alone does not keep the UI isolate responsive.
// Pass only the payload and passphrase, never the view model or database, to the worker isolate.
Future<String> _decryptInBackground((String, String) input) => decryptBackup(input.$1, input.$2);
Future<String> _encryptInBackground((String, String) input) => encryptBackup(input.$1, input.$2);

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
  BackupViewModel(
    this._app, {
    CrashLog? crashLog,
    SshHostKeyTrust? hostKeyTrust,
    this.operationNotifications,
  }) : crashLog = crashLog ?? CrashLog.instance,
       hostKeyTrust = hostKeyTrust ?? SshHostKeyTrust(SecureHostKeyStore());

  final AppState _app;
  final LongOperationNotifications? operationNotifications;
  int _operationSequence = 0;

  String _startOperation(String label) {
    final id = 'backup-${DateTime.now().microsecondsSinceEpoch}-${_operationSequence++}';
    final notifications = operationNotifications;
    if (notifications != null) {
      unawaited(
        notifications.start(id: id, label: label, destination: 'backup').then(_noteStartResult),
      );
    }
    return id;
  }

  void _finishOperation(String id, bool success) {
    final notifications = operationNotifications;
    if (notifications != null) {
      unawaited(notifications.finish(id: id, success: success));
    }
  }

  final CrashLog crashLog;

  /// Pinned host keys, which travel with the hosts in a backup.
  final SshHostKeyTrust hostKeyTrust;

  /// Set when the last export could not read the trust store, so the file went out without the
  /// pinned host keys it should have carried.
  ///
  /// Silence here was the defect. Compose lets `exportEntries()` throw and fails the whole backup
  /// (`ui/AppViewModel.kt:11714`); Flutter swallowed it and wrote a file that looked complete. The
  /// user only found out at restore time, when every host had quietly dropped from "verified
  /// against a pinned key" to trust-on-first-use — which is the one thing pinning exists to catch.
  bool _hostKeysOmitted = false;

  /// Pinned host keys for the export, or none if the trust store cannot be read.
  ///
  /// Still tolerant, deliberately: a locked or unavailable keystore must not cost the user every
  /// other section. What changes is that the omission is now reported rather than hidden.
  Future<Map<String, String>> _pinnedHostKeys() async {
    try {
      return await hostKeyTrust.exportEntries();
    } catch (_) {
      _hostKeysOmitted = true;
      return const {};
    }
  }

  bool _disposed = false;

  /// Surfaces a refused foreground-service start, and only a refused one.
  ///
  /// The result used to be discarded entirely. A refusal means the work the user just started will
  /// not survive them switching away, which is the whole point of the service — so it is worth
  /// saying, once, in this screen's existing error surface. `unsupported` stays silent: iOS and
  /// desktop have no foreground service and never will, and a permanent unactionable warning is
  /// worse than none at all.
  void _noteStartResult(LongOperationStart result) {
    final warning = result.warning;
    if (warning == null || _disposed) return;
    if (_error == warning) return;
    _error = warning;
    _safeNotify();
  }

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
  ///
  /// The "loaded" flag is set *after* the read succeeds, not before it. Setting it first meant a
  /// failed read marked the selection loaded anyway: the screen silently fell back to the default —
  /// which is *everything* — and a later call returned early rather than retrying. A user who had
  /// deliberately excluded credentials or crash logs would have had them back in the file without
  /// being told, which is the wrong direction for that mistake to go.
  Future<void> loadSelection() async {
    if (_selectionLoaded || _selectionLoading) return;
    _selectionLoading = true;
    try {
      final stored = await _app.repository.getSetting('backup_export_selection');
      if (_disposed) return;
      _selectionLoaded = true;
      if (stored == null || stored.trim().isEmpty) return;
      _selection = BackupSelection.decode(stored);
      _safeNotify();
    } catch (_) {
      // Deliberately leaves `_selectionLoaded` false so the next visit tries again. What the user
      // is looking at is not their selection, and that is worth saying before they export.
      if (_disposed) return;
      _error =
          'Your saved backup selection could not be read, so this is showing the default — '
          'everything. Check the sections below before exporting.';
      _safeNotify();
    } finally {
      _selectionLoading = false;
    }
  }

  bool _selectionLoaded = false;
  bool _selectionLoading = false;

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
  String _busyMessage = 'Working…';
  String? _error;
  String? _status;

  bool get busy => _busy;
  String get busyMessage => _busyMessage;
  String? get error => _error;
  String? get status => _status;

  /// Whether [status] reports work that finished, rather than explaining why none did.
  ///
  /// The message card is painted from this. Without it a cancelled save rendered in the same green
  /// as a completed one, so the screen said "nothing was written" in the colour it uses for
  /// success — which is worse than the silence it replaced.
  bool get statusIsSuccess => _statusIsSuccess;
  bool _statusIsSuccess = false;

  void dismissMessages() {
    _error = null;
    _status = null;
    _statusIsSuccess = false;
    notifyListeners();
  }

  // ── export ──────────────────────────────────────────────────────────────────

  /// Builds the backup file's contents, or null when it could not be produced.
  ///
  /// The passphrase is required whenever the selection is sensitive — this is not a preference the
  /// caller can skip, because the alternative is every stored secret in plain text on disk.
  Future<String?> exportBackup(String passphrase) async {
    if (_busy) return null;
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

    final operationId = _startOperation('Exporting OmniTerm backup');
    var succeeded = false;
    _busy = true;
    _busyMessage = 'Creating backup…';
    _error = null;
    // Cleared at the start, as `inspectBackup` and `importBackup` already do. Without it a previous
    // "Backup saved to …" stayed on screen through the next export — including one the user then
    // cancelled — so the screen showed a success message for a file that was never written.
    _status = null;
    _statusIsSuccess = false;
    _hostKeysOmitted = false;
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
        // `BackupPayload.encode` drops these unless the closed selection carries servers, so a
        // trust-store failure is only worth reading — or reporting — when they would be written.
        knownHosts: _selection.withReferentialClosure().contains(BackupSection.servers)
            ? await _pinnedHostKeys()
            : const {},
      );

      // An unencrypted export is only reachable for a selection with nothing sensitive in it.
      // No status here on purpose. The export is only half the job now that the file dialog
      // follows it, and "Backup ready." left standing after a cancelled save would claim a file
      // that was never written. The save reports the real outcome.
      final output = passphrase.isEmpty
          ? json
          : await compute(_encryptInBackground, (json, passphrase));
      succeeded = true;
      return output;
    } on BackupException catch (e) {
      _error = e.message;
      return null;
    } catch (e) {
      _error = 'Could not build the backup: $e';
      return null;
    } finally {
      _busy = false;
      _finishOperation(operationId, succeeded);
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
    // Fire-and-forget, but not fire-and-ignore. When this write failed the file was still saved and
    // the screen still said "last backup: just now" — and then the next launch read the old value
    // back and said something else. The file existing is true and is not walked back; what may not
    // survive is the record of *when*, and the user is told that rather than left to conclude the
    // backup never happened.
    unawaited(
      _app.repository
          .insertSetting('backup_last_export_time', '${now.millisecondsSinceEpoch}')
          .catchError((Object _) {
            if (_disposed) return;
            _status =
                '${_status ?? 'Backup saved.'} The time of this backup could not be recorded, so '
                'this screen may not show it next time. The file itself is saved.';
            _safeNotify();
          }),
    );
    _error = null;
    _statusIsSuccess = true;
    _status = [
      location == null ? 'Backup saved.' : 'Backup saved to $location',
      if (encrypted)
        'It is encrypted with the passphrase you chose. Without that passphrase it cannot be '
            'opened, and nobody can reset it.'
      else
        'It is not encrypted, because nothing sensitive was selected. Anyone who opens the file can '
            'read it.',
      // A partial backup the user knows about is recoverable; one they do not is not.
      if (_hostKeysOmitted)
        'The pinned host keys could NOT be read, so they are not in this file. Restoring it will '
            'leave those hosts trusting the next key they are offered instead of the one you '
            'verified. Back up again once the device keystore is available.',
    ].join(' ');
    _safeNotify();
  }

  /// Report that the user backed out of the file dialog.
  ///
  /// Not an error, and not silence either. By this point the backup has been built and possibly
  /// encrypted, and the screen has been showing "Creating backup…" while that happened. Ending
  /// that with nothing at all leaves the user unsure whether a file exists somewhere.
  void reportSaveCancelled() =>
      reportCancelled('Backup not saved — the file dialog was cancelled. Nothing was written.');

  /// Report that the user backed out, whichever step they backed out of.
  ///
  /// Not an error, and not silence. Every one of these points sits *after* the user asked for
  /// something — and the later ones sit after real work: by the time the restore selection appears,
  /// the file has been read and decrypted. Ending that with a blank screen leaves them unsure
  /// whether anything changed, which for a restore is the one question that matters.
  void reportCancelled(String message) {
    _error = null;
    _statusIsSuccess = false;
    _status = message;
    _safeNotify();
  }

  void reportSaveFailed(String? error) {
    _status = null;
    _statusIsSuccess = false;
    _error = error ?? 'The file could not be saved.';
    _safeNotify();
  }

  // ── import ──────────────────────────────────────────────────────────────────

  /// True when [contents] looks like an encrypted envelope rather than plain JSON.
  ///
  /// Lets the UI ask for a passphrase only when one is needed, instead of demanding one for a file
  /// that does not have any.
  static bool looksEncrypted(String contents) {
    if (contents.length > BackupLimits.maxInputChars) return false;
    try {
      validateBackupJsonDepth(contents);
      final root = jsonDecode(contents);
      return root is Map && ['salt', 'iv', 'data'].any(root.containsKey);
    } catch (_) {
      return false;
    }
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
    if (_busy) return null;
    _busy = true;
    _busyMessage = looksEncrypted(contents) ? 'Decrypting backup…' : 'Reading backup…';
    _error = null;
    _status = null;
    _safeNotify();
    try {
      final json = looksEncrypted(contents)
          ? await compute(_decryptInBackground, (contents, passphrase))
          : contents;
      final decoded = readBackupDocument(json);
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
        plainJson: jsonEncode(decoded),
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
    if (_busy) return null;
    final operationId = _startOperation('Restoring OmniTerm backup');
    var succeeded = false;
    _busy = true;
    _busyMessage = looksEncrypted(contents) ? 'Decrypting backup…' : 'Restoring backup…';
    _error = null;
    _status = null;
    _safeNotify();

    try {
      var json = looksEncrypted(contents)
          ? await compute(_decryptInBackground, (contents, passphrase))
          : contents;
      _busyMessage = 'Restoring backup…';
      _safeNotify();
      // Normalize before filtering; otherwise selecting Kotlin scripts/settings silently removes
      // the wrong fields, and selecting hosts can accidentally bypass version validation.
      json = jsonEncode(readBackupDocument(json));

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
      final skippedServerMessages = <String>[];
      final counts = await _app.repository.inTransaction(
        () => BackupPayload.restore(
          RepositoryRestoreTarget(_app.repository),
          json,
          skippedServerMessages: skippedServerMessages,
        ),
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
      if (skippedServerMessages.isNotEmpty) {
        _status = '$_status\n${skippedServerMessages.join('\n')}';
      }
      _statusIsSuccess = true;
      succeeded = true;
      return counts;
    } on BackupException catch (e) {
      _error = e.message;
      return null;
    } catch (e) {
      _error = 'Could not restore that backup: $e';
      return null;
    } finally {
      _busy = false;
      _finishOperation(operationId, succeeded);
      _safeNotify();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
