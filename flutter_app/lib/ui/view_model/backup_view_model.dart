import 'package:flutter/foundation.dart';

import '../../data/backup/backup_envelope.dart';
import '../../data/backup/backup_payload.dart';
import '../../domain/backup_selection.dart';
import 'app_state.dart';

/// The Backup tool's state and actions, split out of `BackupToolView` in `ui/ToolsScreen.kt`.
///
/// This class produces and consumes the backup *text*; the screen hands it to the platform's
/// document picker. Keeping the two apart is what lets the whole export/restore path be tested
/// without a file dialog, and it is why the reporting helpers below exist — the outcome of writing
/// the file is something only the caller knows.
class BackupViewModel extends ChangeNotifier {
  BackupViewModel(this._app);

  final AppState _app;

  bool _disposed = false;

  void _safeNotify() {
    if (!_disposed) notifyListeners();
  }

  BackupSelection _selection = BackupSelection.all();

  BackupSelection get selection => _selection;

  void toggleSection(BackupSection section, {required bool enabled}) {
    _selection = _selection.toggled(section, enabled: enabled);
    notifyListeners();
  }

  void selectAll() {
    _selection = BackupSelection.all();
    notifyListeners();
  }

  void selectNone() {
    _selection = const BackupSelection.none();
    notifyListeners();
  }

  /// True when the current selection would carry credentials or host identities.
  ///
  /// Drives the requirement to encrypt: an unencrypted export of this would put every stored
  /// password into a file the user may well drop in a cloud drive.
  bool get requiresPassphrase => _selection.hasSensitiveData;

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

  /// Report a completed save.
  ///
  /// The location is named rather than a bare "done": a backup the user cannot find is one they
  /// will assume did not happen. The passphrase reminder is repeated here, at the moment the file
  /// becomes a real, portable thing that can be lost — which is when it matters, not when the
  /// passphrase was chosen.
  void reportSaved(String? location, {required bool encrypted}) {
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

  /// Restores [contents] into the database.
  ///
  /// **Additive:** existing rows are kept and the backup's rows are added alongside them. Wiping
  /// first would make restoring the wrong file unrecoverable, and there is no undo for that. The UI
  /// says so before running.
  Future<Map<String, int>?> importBackup(String contents, String passphrase) async {
    _busy = true;
    _error = null;
    _status = null;
    _safeNotify();

    try {
      final json = looksEncrypted(contents) ? await decryptBackup(contents, passphrase) : contents;

      final counts = await BackupPayload.restore(RepositoryRestoreTarget(_app.repository), json);

      final restored = counts.entries
          .where((e) => !e.key.endsWith('Skipped'))
          .fold<int>(0, (sum, e) => sum + e.value);
      // Naming every skip rather than hiding it: a rule silently missing after a restore is a rule
      // no longer watching anything, and a missing tunnel is a port that never opens.
      final skips = <String>[
        if ((counts['alertRulesSkipped'] ?? 0) > 0) '${counts['alertRulesSkipped']} alert rule(s)',
        if ((counts['portForwardsSkipped'] ?? 0) > 0) '${counts['portForwardsSkipped']} tunnel(s)',
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
