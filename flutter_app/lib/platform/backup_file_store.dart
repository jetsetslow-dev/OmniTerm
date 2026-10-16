import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_file_dialog/flutter_file_dialog.dart';

/// Result of a save: where it went, or why it did not.
enum BackupSaveOutcome { saved, cancelled, failed }

class BackupSaveResult {
  const BackupSaveResult(this.outcome, {this.location, this.error});

  final BackupSaveOutcome outcome;

  /// The path or content URI the platform reported. Shown back to the user so "saved" names a place
  /// they can go and look, rather than being a claim they have to take on trust.
  final String? location;
  final String? error;
}

/// Reads and writes backup files through the platform's own document picker.
///
/// Deliberately the *system* picker rather than a path this app chooses: the user decides where a
/// file holding their host list and credentials lands, and the app never gains standing access to a
/// directory it was not handed.
///
/// Wrapped behind a class so the backup screen depends on an injectable collaborator rather than a
/// static plugin call, which is what lets the flow be tested without a file dialog (Convention 4).
class BackupFileStore {
  const BackupFileStore();

  /// The MIME type the picker filters on.
  ///
  /// `application/octet-stream` rather than a JSON type: an encrypted backup is not JSON, and
  /// claiming otherwise invites other apps to try to parse it.
  static const mimeType = 'application/octet-stream';

  Future<BackupSaveResult> save(String fileName, String contents) async {
    try {
      final location = await FlutterFileDialog.saveFile(
        params: SaveFileDialogParams(
          // Handed over as bytes rather than written to a temp file first. A backup can contain
          // every credential the user has, and a staging copy in the cache directory would outlive
          // the save — including when the user cancels it.
          data: Uint8List.fromList(utf8.encode(contents)),
          fileName: fileName,
          mimeTypesFilter: const [mimeType],
        ),
      );
      return location == null
          ? const BackupSaveResult(BackupSaveOutcome.cancelled)
          : BackupSaveResult(BackupSaveOutcome.saved, location: location);
    } catch (e) {
      return BackupSaveResult(BackupSaveOutcome.failed, error: '$e');
    }
  }

  /// Reads a chosen file, or null when the user cancelled.
  ///
  /// Throws [BackupReadException] for a file that cannot be read or is not text, so the caller can
  /// tell "you cancelled" from "that file is not a backup".
  Future<String?> open() async {
    final String? path;
    try {
      path = await FlutterFileDialog.pickFile(
        params: const OpenFileDialogParams(
          mimeTypesFilter: [mimeType],
          fileExtensionsFilter: ['omnibak', 'json', 'txt'],
          // Copied into the app's cache so the read cannot fail on a URI the picker granted only
          // for the length of the dialog.
          copyFileToCacheDir: true,
        ),
      );
    } catch (e) {
      throw BackupReadException('The file picker could not be opened: $e');
    }
    if (path == null) return null;

    final file = File(path);
    final int length;
    try {
      length = await file.length();
    } catch (e) {
      throw BackupReadException('That file could not be read: $e');
    }
    if (length > maxBackupBytes) {
      // Read as a whole string, so an enormous file would be an out-of-memory crash rather than a
      // message. The limit is far above any real backup and far below anything that hurts.
      throw BackupReadException(
        'That file is ${(length / 1024 / 1024).toStringAsFixed(1)} MB, which is far larger than any '
        'OmniTerm backup. Check you picked the right file.',
      );
    }

    try {
      return await file.readAsString();
    } on FileSystemException catch (e) {
      throw BackupReadException('That file could not be read: ${e.message}');
    } on FormatException {
      // A binary file reaches here as invalid UTF-8. Saying so is more useful than the decoder's
      // byte-offset complaint.
      throw BackupReadException('That file is not a text backup.');
    }
  }

  /// 64 MB. A real backup is kilobytes; this only exists to stop a mis-picked video file being
  /// loaded into memory in one piece.
  static const maxBackupBytes = 64 * 1024 * 1024;
}

class BackupReadException implements Exception {
  const BackupReadException(this.message);

  final String message;

  @override
  String toString() => message;
}
