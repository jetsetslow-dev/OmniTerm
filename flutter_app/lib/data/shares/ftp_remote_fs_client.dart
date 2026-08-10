import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ftpconnect/ftpconnect.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../remote_models.dart';
import 'remote_fs_client.dart';

/// FTP implementation of the shared file-browser contract.
///
/// `ftpconnect` exposes local-file transfers rather than byte streams, so streams are staged in the
/// app cache and deleted in `finally`. The remote API remains streaming and memory-bounded.
class FtpRemoteFsClient extends RemoteFsClient {
  FtpRemoteFsClient({
    required String host,
    required int port,
    required String username,
    required String password,
  }) : _ftp = FTPConnect(host, port: port, user: username, pass: password, timeout: 20);

  final FTPConnect _ftp;
  bool _connected = false;
  bool _closed = false;
  Future<void> _tail = Future.value();

  Future<T> _serial<T>(Future<T> Function() action) {
    final result = Completer<T>();
    _tail = _tail.then((_) async {
      if (_closed) throw StateError('FTP connection is closed.');
      try {
        if (!_connected) {
          _connected = await _ftp.connect();
          if (!_connected) throw const FileSystemException('FTP login failed.');
        }
        result.complete(await action());
      } catch (error, stack) {
        result.completeError(error, stack);
      }
    });
    return result.future;
  }

  @override
  Future<String> home() => _serial(_ftp.currentDirectory);

  @override
  Future<List<SftpFile>> list(String path) => _serial(() async {
    if (!await _ftp.changeDirectory(path)) {
      throw FileSystemException('Cannot open FTP directory', path);
    }
    final entries = await _ftp.listDirectoryContent();
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
  Future<void> mkdir(String path) => _serial(() async {
    if (!await _ftp.makeDirectory(path)) {
      throw FileSystemException('Could not create FTP directory', path);
    }
  });

  @override
  Future<void> rename(String oldPath, String newPath, {bool isDirectory = false}) =>
      _serial(() async {
        if (!await _ftp.rename(oldPath, newPath)) {
          throw FileSystemException('Could not rename FTP item', oldPath);
        }
      });

  @override
  Future<void> delete(String path, {required bool isDirectory}) => _serial(() async {
    final ok = isDirectory ? await _ftp.deleteDirectory(path) : await _ftp.deleteFile(path);
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
  }) => _serial(() async {
    final temp = await _temporaryFile();
    try {
      var copied = 0;
      var total = 0;
      final ok = await _ftp.downloadFile(
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
  }) => _serial(() async {
    final temp = await _temporaryFile();
    try {
      final sink = temp.openWrite();
      await sink.addStream(input);
      await sink.close();
      final ok = await _ftp.uploadFile(
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
    await downloadTo(path, sink.sink);
    await sink.close();
    await subscription.asFuture<void>();
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
    if (_connected) unawaited(_ftp.disconnect());
  }
}
