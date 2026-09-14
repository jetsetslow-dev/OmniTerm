import 'dart:async';

import 'package:omniterm/platform/backup_file_store.dart';

/// A [BackupFileStore] that stands in for the system file dialog.
class FakeBackupFileStore implements BackupFileStore {
  FakeBackupFileStore({this.saveResult, this.openContents, this.openError});

  /// What `save` reports back. Defaults to a successful save.
  BackupSaveResult? saveResult;

  /// What `open` returns; null models the user cancelling the picker.
  String? openContents;

  /// When set, `open` throws it — the "that file is not a backup" path.
  BackupReadException? openError;

  final List<({String fileName, String contents})> saved = [];
  int openCalls = 0;

  /// Called when `save` is invoked, so a test can record when the picker would have appeared
  /// relative to other system surfaces.
  void Function()? onSave;

  /// Holds `save` open, standing in for the time the system file picker is on screen. A test
  /// completes it to model the user finally choosing a location. That window is when the Backup
  /// screen can be unmounted, so it is the only way to reach the "finished while away" path.
  Completer<void>? saveGate;

  @override
  Future<BackupSaveResult> save(String fileName, String contents) async {
    onSave?.call();
    final gate = saveGate;
    if (gate != null) await gate.future;
    saved.add((fileName: fileName, contents: contents));
    return saveResult ??
        const BackupSaveResult(BackupSaveOutcome.saved, location: '/storage/Download/backup');
  }

  @override
  Future<String?> open() async {
    openCalls++;
    final error = openError;
    if (error != null) throw error;
    return openContents;
  }
}
