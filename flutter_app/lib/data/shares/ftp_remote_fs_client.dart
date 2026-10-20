import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:ftpconnect/ftpconnect.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../remote_models.dart';
import 'remote_fs_client.dart';

/// FTP implementation of the shared file-browser contract, matching the Kotlin app's
/// `FtpFsClient` in how it holds connections:
///
/// - **Binary mode on every connection.** FTP starts in ASCII mode, where a server that honours it
///   rewrites line endings in transit and corrupts every binary file. Kotlin sets
///   `BINARY_FILE_TYPE` after login and fails if the server refuses; so does this.
/// - **A dead control connection is replaced, not reused.** Servers drop idle sessions (vsftpd after
///   five minutes by default). The connection is probed with NOOP before reuse, and any failure
///   discards it, so the next action redials instead of failing until the share is reopened. Only a
///   failure where the transport itself died is retried once, as in Kotlin.
/// - **Transfers get their own connection.** One control channel cannot multiplex, so a long
///   download would otherwise park every listing behind it. Transfers are never retried: the
///   caller's stream is already partly written or read when one fails.
///
/// `ftpconnect` exposes local-file transfers rather than byte streams, so streams are staged in the
/// app cache and deleted in `finally`. The remote API remains streaming and memory-bounded.
class FtpRemoteFsClient extends RemoteFsClient {
  FtpRemoteFsClient({
    required String host,
    required int port,
    required String username,
    required String password,
    @visibleForTesting FTPConnect Function()? connector,
  }) : _newConnection =
           connector ??
           (() => FTPConnect(host, port: port, user: username, pass: password, timeout: 20));

  final FTPConnect Function() _newConnection;
  FTPConnect? _control;
  final Set<FTPConnect> _transfers = {};
  bool _closed = false;
  Future<void> _tail = Future.value();

  /// A logged-in connection in binary mode with the best list command the server offers.
  Future<FTPConnect> _dial() async {
    final ftp = _newConnection();
    if (!await ftp.connect()) throw const FileSystemException('FTP login failed.');
    try {
      final type = await ftp.sendCustomCommand('TYPE I');
      if (!type.isSuccessCode()) {
        throw FileSystemException('FTP server rejected binary mode: ${type.message}'.trim());
      }
      // Recorded in ftpconnect too, so its own SIZE fallback does not switch back to ASCII.
      await ftp.setTransferType(TransferType.binary);
      // MLSD has structured timestamps and types, so prefer it when the server advertises the
      // RFC 3659 MLST capability. It is not universal: current vsftpd, among other real servers,
      // can answer `500 Unknown command` to MLSD. ftpconnect defaults to MLSD without probing,
      // which makes an otherwise healthy share impossible to open. LIST is the interoperable
      // fallback; a rejected or unsupported FEAT command leaves that fallback selected.
      ftp.listCommand = ListCommand.list;
      try {
        final features = await ftp.sendCustomCommand('FEAT');
        ftp.listCommand = ftpListCommandForFeatures(features.message.toString());
      } catch (_) {
        // RFC 2389 FEAT is optional. Login succeeded, so do not reject an older server merely
        // because capability discovery is unavailable.
      }
      return ftp;
    } catch (_) {
      _hangUp(ftp);
      rethrow;
    }
  }

  void _hangUp(FTPConnect ftp) => unawaited(ftp.disconnect().catchError((Object _) => false));

  /// The shared control connection, probed before reuse as Kotlin's `connectLocked` does.
  Future<FTPConnect> _controlConnection() async {
    final existing = _control;
    if (existing != null) {
      try {
        if ((await existing.sendCustomCommand('NOOP')).isSuccessCode()) return existing;
      } catch (_) {
        // Dropped by the server or the network; replaced below.
      }
      _control = null;
      _hangUp(existing);
    }
    return _control = await _dial();
  }

  /// Runs [action] on the control connection, one at a time.
  Future<T> _serial<T>(Future<T> Function(FTPConnect ftp) action) {
    final result = Completer<T>();
    _tail = _tail.then((_) async {
      for (var attempt = 0; ; attempt++) {
        if (_closed) {
          result.completeError(StateError('FTP connection is closed.'));
          return;
        }
        FTPConnect? ftp;
        try {
          ftp = await _controlConnection();
          result.complete(await action(ftp));
          return;
        } catch (error, stack) {
          // A failed command leaves the control channel in an unknown state: always start over.
          if (ftp != null && identical(_control, ftp)) {
            _control = null;
            _hangUp(ftp);
          }
          if (attempt == 0 && ftpTransportDied(error)) continue;
          result.completeError(error, stack);
          return;
        }
      }
    });
    return result.future;
  }

  /// Runs a transfer on a connection of its own, closed afterwards and never retried.
  Future<T> _transfer<T>(Future<T> Function(FTPConnect ftp) action) async {
    if (_closed) throw StateError('FTP connection is closed.');
    final ftp = await _dial();
    _transfers.add(ftp);
    try {
      return await action(ftp);
    } finally {
      _transfers.remove(ftp);
      _hangUp(ftp);
    }
  }

  @override
  Future<String> home() => _serial((ftp) => ftp.currentDirectory());

  @override
  Future<List<SftpFile>> list(String path) => _serial((ftp) async {
    if (!await ftp.changeDirectory(path)) {
      throw FileSystemException('Cannot open FTP directory', path);
    }
    final entries = await ftp.listDirectoryContent();
    return [
      for (final entry in entries)
        if (entry.name != '.' && entry.name != '..')
          SftpFile(
            name: entry.name,
            isDirectory: entry.type == FTPEntryType.dir,
            size: entry.size ?? 0,
            modDate: formatFsDate(entry.modifyTime?.millisecondsSinceEpoch ?? 0),
            modTimeSeconds: (entry.modifyTime?.millisecondsSinceEpoch ?? 0) ~/ 1000,
          ),
    ];
  });

  @override
  Future<void> mkdir(String path) => _serial((ftp) async {
    if (!await ftp.makeDirectory(path)) {
      throw FileSystemException('Could not create FTP directory', path);
    }
  });

  @override
  Future<void> rename(String oldPath, String newPath, {bool isDirectory = false}) =>
      _serial((ftp) async {
        if (!await ftp.rename(oldPath, newPath)) {
          throw FileSystemException('Could not rename FTP item', oldPath);
        }
      });

  @override
  Future<void> delete(String path, {required bool isDirectory}) => _serial((ftp) async {
    final ok = isDirectory ? await ftp.deleteDirectory(path) : await ftp.deleteFile(path);
    if (!ok) throw FileSystemException('Could not delete FTP item', path);
  });

  Future<File> _temporaryFile() async {
    final directory = await getTemporaryDirectory();
    return File(p.join(directory.path, 'omniterm-ftp-${const Uuid().v4()}'));
  }

  @override
  Future<int> downloadTo(
    String path,
    StreamSink<List<int>> output, {
    void Function(int copied, int total)? onProgress,
  }) => _transfer((ftp) async {
    final temp = await _temporaryFile();
    try {
      var copied = 0;
      var total = 0;
      final ok = await ftp.downloadFile(
        path,
        temp,
        onProgress: (_, received, fileSize) {
          copied = received;
          total = fileSize;
          onProgress?.call(received, fileSize);
        },
      );
      if (!ok) throw FileSystemException('Could not download FTP file', path);
      await for (final chunk in temp.openRead()) {
        output.add(chunk);
      }
      onProgress?.call(copied, total);
      return copied == 0 ? await temp.length() : copied;
    } finally {
      if (await temp.exists()) await temp.delete();
    }
  });

  @override
  Future<void> uploadStream(
    String path,
    Stream<List<int>> input,
    int totalBytes, {
    void Function(int copied, int total)? onProgress,
  }) => _transfer((ftp) async {
    final temp = await _temporaryFile();
    try {
      final sink = temp.openWrite();
      await sink.addStream(input);
      await sink.close();
      final ok = await ftp.uploadFile(
        temp,
        sRemoteName: path,
        onProgress: (_, sent, total) => onProgress?.call(sent, total),
      );
      if (!ok) throw FileSystemException('Could not upload FTP file', path);
      onProgress?.call(totalBytes, totalBytes);
    } finally {
      if (await temp.exists()) await temp.delete();
    }
  });

  @override
  bool get supportsTextEditing => true;

  @override
  Future<String> readText(String path, {int maxBytes = 512 * 1024}) async {
    final bytes = <int>[];
    final sink = StreamController<List<int>>();
    final subscription = sink.stream.listen((chunk) {
      if (bytes.length + chunk.length > maxBytes) {
        throw FileSystemException('FTP file is larger than the editor limit', path);
      }
      bytes.addAll(chunk);
    });
    final completed = subscription.asFuture<void>();
    await downloadTo(path, sink.sink);
    await sink.close();
    await completed;
    return utf8.decode(bytes, allowMalformed: true);
  }

  @override
  Future<int> writeText(String path, String content) async {
    final bytes = utf8.encode(content);
    await uploadStream(path, Stream.value(bytes), bytes.length);
    return bytes.length;
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    final control = _control;
    _control = null;
    if (control != null) _hangUp(control);
    for (final ftp in _transfers.toList()) {
      _hangUp(ftp);
    }
    _transfers.clear();
  }
}

/// Selects the most precise directory command the FTP server explicitly supports.
ListCommand ftpListCommandForFeatures(String reply) {
  final features = reply.toUpperCase().split(RegExp(r'\s+')).toSet();
  return features.contains('MLST') || features.contains('MLSD')
      ? ListCommand.mlsd
      : ListCommand.list;
}

/// True when [error] means the connection itself is gone (refused, reset, timed out waiting for a
/// reply), as opposed to the server answering a command with a refusal. Only the former is worth a
/// second attempt on a fresh connection.
bool ftpTransportDied(Object error) =>
    error is SocketException ||
    (error is FTPConnectException && error.message.contains('Timeout reached'));
