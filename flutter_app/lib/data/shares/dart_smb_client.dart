import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dart_smb2/dart_smb2.dart' as smb2;

import '../remote_models.dart';
import 'platform_smb_client.dart';
import 'remote_fs_client.dart';

/// SMB2/3 client for Apple platforms, backed by the dynamically linked
/// libsmb2 XCFramework shipped by `dart_smb2`.
///
/// Android deliberately continues to use smbj through [PlatformSmbClient].
/// Besides retaining the mature implementation already exercised by the
/// Kotlin app, that also preserves support for non-standard SMB ports; the
/// libsmb2 wrapper currently connects only to the standard port.
class DartSmbClient extends RemoteFsClient {
  DartSmbClient(this.endpoint);

  final SmbEndpoint endpoint;

  Future<smb2.Smb2Pool>? _connection;
  bool _closed = false;
  bool _cancelled = false;

  Future<smb2.Smb2Pool> _pool() {
    if (_closed) {
      return Future.error(SmbException('This share connection has been closed.'));
    }
    if (endpoint.port != 445) {
      return Future.error(
        SmbException(
          'SMB on iPhone and iPad currently requires port 445. '
          '${endpoint.label} is configured for port ${endpoint.port}.',
        ),
      );
    }
    return _connection ??= _connect();
  }

  Future<smb2.Smb2Pool> _connect() async {
    try {
      final pool = await smb2.Smb2Pool.connect(
        host: endpoint.host,
        share: endpoint.shareName,
        user: endpoint.anonymous ? null : endpoint.username,
        password: endpoint.anonymous ? null : endpoint.password,
        domain: endpoint.anonymous || endpoint.domain.isEmpty ? null : endpoint.domain,
        workers: 1,
      );
      if (_closed) {
        await pool.disconnect();
        throw SmbException('This share connection has been closed.');
      }
      return pool;
    } on SmbException {
      rethrow;
    } on Object catch (error) {
      _connection = null;
      throw _error('connect to', error);
    }
  }

  String _path(String path) {
    var relative = path.trim();
    while (relative.startsWith('/')) {
      relative = relative.substring(1);
    }
    while (relative.endsWith('/') && relative.isNotEmpty) {
      relative = relative.substring(0, relative.length - 1);
    }
    return relative;
  }

  SmbException _error(String operation, Object error) => SmbException(
    'Could not $operation ${endpoint.label}: $error',
    code: error is smb2.Smb2Exception ? error.type.name : null,
  );

  Future<T> _run<T>(String operation, Future<T> Function(smb2.Smb2Pool) body) async {
    try {
      return await body(await _pool());
    } on SmbException {
      rethrow;
    } on Object catch (error) {
      throw _error(operation, error);
    }
  }

  @override
  Future<String> home() async => '/';

  @override
  Future<List<SftpFile>> list(String path) => _run('list', (pool) async {
    final entries = await pool.listDirectory(_path(path));
    return entries
        .where((entry) => entry.name != '.' && entry.name != '..')
        .map(
          (entry) => SftpFile(
            name: entry.name,
            isDirectory: entry.isDirectory,
            size: entry.isDirectory ? 0 : entry.size,
            modDate: formatFsDate(entry.stat.modified.millisecondsSinceEpoch),
            modTimeSeconds: entry.stat.modified.millisecondsSinceEpoch ~/ 1000,
          ),
        )
        .toList(growable: false);
  });

  @override
  Future<void> mkdir(String path) => _run('create a folder on', (pool) => pool.mkdir(_path(path)));

  @override
  Future<void> rename(String oldPath, String newPath, {bool isDirectory = false}) =>
      _run('rename an item on', (pool) => pool.rename(_path(oldPath), _path(newPath)));

  @override
  Future<void> delete(String path, {required bool isDirectory}) => _run(
    'delete an item from',
    (pool) => isDirectory ? pool.rmdir(_path(path)) : pool.deleteFile(_path(path)),
  );

  @override
  Future<int> downloadTo(
    String path,
    StreamSink<List<int>> output, {
    void Function(int copied, int total)? onProgress,
  }) => _run('download from', (pool) async {
    _cancelled = false;
    var copied = 0;
    await for (final chunk in pool.streamFile(
      _path(path),
      isCanceled: () => _closed || _cancelled,
      onProgress: onProgress,
    )) {
      output.add(chunk);
      copied += chunk.length;
    }
    return copied;
  });

  @override
  Future<void> uploadStream(
    String path,
    Stream<List<int>> input,
    int totalBytes, {
    void Function(int copied, int total)? onProgress,
  }) => _run('upload to', (pool) async {
    _cancelled = false;
    final progress = TransferProgressThrottle(onProgress, totalBytes);
    final chunks = input.map((chunk) {
      if (_closed || _cancelled) {
        throw SmbException('The upload was cancelled.');
      }
      progress.add(chunk.length);
      return asBytes(chunk);
    });
    await pool.streamWrite(_path(path), chunks);
    progress.finish();
  });

  @override
  bool get supportsTextEditing => true;

  @override
  Future<String> readText(String path, {int maxBytes = 512 * 1024}) async {
    final bytes = BytesBuilder(copy: false);
    await _run('read from', (pool) async {
      await for (final chunk in pool.streamFile(
        _path(path),
        isCanceled: () => _closed || _cancelled,
      )) {
        if (bytes.length + chunk.length > maxBytes) {
          throw SmbException('The SMB file is larger than the editor limit.');
        }
        bytes.add(chunk);
      }
    });
    return utf8.decode(bytes.takeBytes(), allowMalformed: true);
  }

  @override
  Future<int> writeText(String path, String content) async {
    final bytes = utf8.encode(content);
    await uploadStream(path, Stream.value(bytes), bytes.length);
    return bytes.length;
  }

  @override
  void cancelActiveTransfers() {
    _cancelled = true;
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    _cancelled = true;
    final connection = _connection;
    _connection = null;
    if (connection != null) {
      unawaited(connection.then((pool) => pool.disconnect(), onError: (_) {}));
    }
  }
}
