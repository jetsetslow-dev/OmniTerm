import 'dart:io';

import 'package:flutter_file_dialog/flutter_file_dialog.dart';

/// A folder the user granted access to, for a batch of saves.
///
/// Holds the platform's handle rather than a path: on Android the grant is a tree URI, which is not
/// a filesystem path and cannot be reconstructed from one.
///
/// [handle] is deliberately opaque — only the [DeviceFileStore] that produced it reads it. That is
/// what lets the batch flow be tested at all: the plugin's own `DirectoryLocation` has a private
/// constructor, so a test could not otherwise produce a destination to save into.
class DeviceFolder {
  const DeviceFolder(this.handle);

  final Object handle;
}

/// What happened to a save.
enum DeviceSaveOutcome { saved, cancelled, failed }

class DeviceSaveResult {
  const DeviceSaveResult(this.outcome, {this.location, this.error});

  const DeviceSaveResult.cancelled() : this(DeviceSaveOutcome.cancelled);

  final DeviceSaveOutcome outcome;

  /// Where the file went, when the platform says. Null is normal on Android, where a content URI is
  /// not a path the user would recognise.
  final String? location;

  final String? error;
}

/// Hands a downloaded remote file to the platform's save dialog.
///
/// Separate from [BackupFileStore] because the two carry different things: a backup is bytes the app
/// built and holds in memory, while this is an arbitrary remote file that may be gigabytes. It is
/// passed by **path**, not by content — buffering a large download in memory to hand it over would
/// fail on exactly the transfers most worth doing.
///
/// A class rather than a function so the SFTP flow can be tested without a system dialog, which is
/// the same reason [BackupFileStore] is one.
class DeviceFileStore {
  const DeviceFileStore();

  /// Asks the user for a file to upload, or null when they backed out.
  ///
  /// Returns a path rather than bytes for the same reason [save] takes one: the file may be large,
  /// and the upload streams it rather than holding it.
  Future<String?> pick() async {
    try {
      return await FlutterFileDialog.pickFile();
    } catch (_) {
      // A picker that will not open is indistinguishable from a cancel as far as this flow goes —
      // there is nothing to upload either way, and an error dialog over a file chooser the user
      // never saw would only confuse.
      return null;
    }
  }

  /// Asks the user for a folder to save into, or null when they backed out.
  ///
  /// Used by the batch download so the destination is chosen **once** rather than once per file: a
  /// save dialog per file turns a twelve-file download into twelve prompts, which is not a batch.
  Future<DeviceFolder?> pickFolder() async {
    try {
      final location = await FlutterFileDialog.pickDirectory();
      return location == null ? null : DeviceFolder(location);
    } catch (_) {
      // Same reasoning as [pick]: a chooser that will not open is indistinguishable from a cancel.
      return null;
    }
  }

  /// Copies the file at [sourcePath] into [folder] under [fileName].
  ///
  /// **Reads the file into memory**, because the platform's directory API takes bytes and there is
  /// no streaming equivalent. The caller is responsible for not handing it something too large —
  /// see `SftpViewModel.batchDownloadByteCeiling`, which is why that ceiling exists at all.
  Future<DeviceSaveResult> saveInto(
    DeviceFolder folder,
    String fileName,
    String sourcePath,
  ) async {
    try {
      final location = await FlutterFileDialog.saveFileToDirectory(
        // Safe because the only thing that produces a [DeviceFolder] here is [pickFolder].
        directory: folder.handle as DirectoryLocation,
        data: await File(sourcePath).readAsBytes(),
        fileName: fileName,
        mimeType: 'application/octet-stream',
      );
      return location == null
          ? const DeviceSaveResult.cancelled()
          : DeviceSaveResult(DeviceSaveOutcome.saved, location: location);
    } catch (e) {
      return DeviceSaveResult(DeviceSaveOutcome.failed, error: '$e');
    }
  }

  /// Offers [sourcePath] to the user under [fileName].
  Future<DeviceSaveResult> save(String fileName, String sourcePath) async {
    try {
      final location = await FlutterFileDialog.saveFile(
        params: SaveFileDialogParams(
          sourceFilePath: sourcePath,
          fileName: fileName,
        ),
      );
      // Null is the user backing out, not a failure — reporting an error for a deliberate cancel
      // teaches people to ignore the messages that matter.
      return location == null
          ? const DeviceSaveResult.cancelled()
          : DeviceSaveResult(DeviceSaveOutcome.saved, location: location);
    } catch (e) {
      return DeviceSaveResult(DeviceSaveOutcome.failed, error: '$e');
    }
  }
}
