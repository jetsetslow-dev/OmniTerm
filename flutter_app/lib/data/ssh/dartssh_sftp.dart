import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

// dartssh2 also exports an SftpFile (a remote file *handle*); ours is a directory entry.
import 'package:dartssh2/dartssh2.dart' hide SftpFile;

import '../remote_models.dart';
import '../shares/remote_fs_client.dart';
import 'ssh_transport.dart';

/// Real SFTP operations over dartssh2's SFTP subsystem, ported from `data/ssh/JschSftp.kt`.
///
/// **Performance shape, preserved verbatim:** authenticating an SSH connection (RSA/ed25519 plus
/// several round-trips) is the expensive part of every SFTP call and dominates on high-latency
/// links. The authenticated connection is therefore kept warm in a shared pool and only a
/// lightweight SFTP client is opened per operation. Navigating between folders then costs one open
/// + `ls` rather than a full handshake — the difference between "instant" and "several seconds" on a
/// remote host.
///
/// Each operation gets its own short-lived SFTP client so a long transfer never blocks a folder
/// listing on the same connection. Jump-host connections are not pooled.
class DartSshSftp extends RemoteFsClient {
  DartSshSftp(this._creds, this._openConnection);

  /// Opens (or borrows) a connection for [SshCredentials]. Supplied by the transport so this class
  /// owns no connection policy of its own.
  final Future<SshConnectionLease> Function(SshCredentials creds) _openConnection;
  final SshCredentials _creds;

  static const _metadataTimeout = Duration(minutes: 2);
  static const _transferTimeout = Duration(hours: 6);

  /// In-flight operations, so [cancelActiveTransfers] can unwind them.
  final Set<SftpClient> _activeClients = {};
  final Set<StreamSubscription<void>> _activeTransfers = {};
  bool _cancelled = false;

  /// Runs [block] against a fresh SFTP client on a (possibly pooled) connection.
  ///
  /// [retryOnStaleConnection] is the important flag. A stale pooled connection usually fails at
  /// client-open — before [block] has done anything — and that phase is always retried once.
  /// Failures *inside* [block] retry only when this allows it: **streaming transfers must pass
  /// false**, because their caller-owned streams are already partially written or consumed, and
  /// re-running the block would silently duplicate downloaded bytes or upload only the leftover
  /// tail.
  Future<T> _withSftp<T>(
    Future<T> Function(SftpClient sftp) block, {
    bool retryOnStaleConnection = false,
    Duration timeout = _metadataTimeout,
  }) {
    return _run(block, retryOnStaleConnection: retryOnStaleConnection).timeout(timeout);
  }

  Future<T> _run<T>(
    Future<T> Function(SftpClient sftp) block, {
    required bool retryOnStaleConnection,
  }) async {
    var attempt = 0;
    while (true) {
      final lease = await _openConnection(_creds);
      SftpClient? sftp;
      try {
        sftp = await lease.client.sftp();
      } catch (e) {
        final dead = lease.isStale;
        lease.evict();
        lease.close();
        if (dead && attempt++ < 1) continue;
        rethrow;
      }

      _activeClients.add(sftp);
      try {
        return await block(sftp);
      } catch (e) {
        // Only a dropped connection warrants eviction and a reconnect. A logical error such as
        // "No such file" must NOT throw away the warm connection — rethrow it untouched.
        if (lease.isStale) {
          lease.evict();
          if (retryOnStaleConnection && attempt++ < 1) {
            continue;
          }
        }
        rethrow;
      } finally {
        _activeClients.remove(sftp);
        sftp.close();
        lease.close();
      }
    }
  }

  @override
  Future<String> home() => _withSftp((sftp) => sftp.absolute('.'), retryOnStaleConnection: true);

  @override
  Future<List<SftpFile>> list(String path) => _withSftp((sftp) async {
    final target = path.trim().isEmpty ? await sftp.absolute('.') : path;
    final entries = await sftp.listdir(target);
    return [
      for (final entry in entries)
        if (entry.filename != '.' && entry.filename != '..')
          SftpFile(
            name: entry.filename,
            isDirectory: entry.attr.isDirectory,
            size: entry.attr.size ?? 0,
            // Rendered from the epoch seconds rather than trusting a server-formatted string:
            // SFTP's longname field is free-form and varies by implementation.
            modDate: formatFsDate((entry.attr.modifyTime ?? 0) * 1000),
            modTimeSeconds: entry.attr.modifyTime ?? 0,
          ),
    ];
  }, retryOnStaleConnection: true);

  @override
  Future<void> mkdir(String path) => _withSftp((sftp) => sftp.mkdir(path));

  @override
  Future<void> rename(String oldPath, String newPath, {bool isDirectory = false}) =>
      _withSftp((sftp) => sftp.rename(oldPath, newPath));

  @override
  Future<void> delete(String path, {required bool isDirectory}) =>
      _withSftp((sftp) => isDirectory ? sftp.rmdir(path) : sftp.remove(path));

  /// Reads at most [maxBytes] of a remote text file.
  ///
  /// The cap is applied while streaming, not after: opening a multi-GB file for editing must cost
  /// at most [maxBytes] of memory rather than the file's size.
  Future<String> readText(String path, {int maxBytes = 512 * 1024}) => _withSftp((sftp) async {
    final file = await sftp.open(path);
    try {
      final builder = BytesBuilder(copy: false);
      await for (final chunk in file.read(length: maxBytes)) {
        builder.add(chunk);
        if (builder.length >= maxBytes) break;
      }
      final bytes = builder.takeBytes();
      final capped = bytes.length <= maxBytes ? bytes : Uint8List.sublistView(bytes, 0, maxBytes);
      // Malformed bytes are replaced rather than thrown on: a config file with one bad byte
      // must still open in the editor.
      return utf8.decode(capped, allowMalformed: true);
    } finally {
      await file.close();
    }
  }, retryOnStaleConnection: true);

  /// Writes [content] to [path] and confirms persistence by reading back the remote size.
  ///
  /// Returns the size the remote reports after the write, so callers can prove the edit landed
  /// rather than assuming a silent success. Returns -1 when the size could not be re-read.
  Future<int> writeText(String path, String content) => _withSftp((sftp) async {
    final bytes = Uint8List.fromList(utf8.encode(content));
    final file = await sftp.open(
      path,
      mode: SftpFileOpenMode.create | SftpFileOpenMode.write | SftpFileOpenMode.truncate,
    );
    try {
      await file.writeBytes(bytes);
    } finally {
      await file.close();
    }
    try {
      return (await sftp.stat(path)).size ?? -1;
    } catch (_) {
      return -1;
    }
  });

  @override
  Future<void> uploadStream(
    String path,
    Stream<List<int>> input,
    int totalBytes, {
    void Function(int copied, int total)? onProgress,
  }) => _withSftp(
    (sftp) async {
      final file = await sftp.open(
        path,
        mode: SftpFileOpenMode.create | SftpFileOpenMode.write | SftpFileOpenMode.truncate,
      );
      final progress = TransferProgressThrottle(onProgress, totalBytes);
      try {
        await for (final chunk in input) {
          if (_cancelled) throw StateError('Transfer cancelled');
          await file.writeBytes(asBytes(chunk), offset: progress.copied);
          progress.add(chunk.length);
        }
        progress.finish();
      } finally {
        await file.close();
      }
    },
    // Never retried: the caller's input stream has already been partially consumed, so a retry
    // would upload only the leftover tail.
    retryOnStaleConnection: false,
    timeout: _transferTimeout,
  );

  @override
  Future<int> downloadTo(
    String path,
    StreamSink<List<int>> output, {
    void Function(int copied, int total)? onProgress,
  }) => _withSftp(
    (sftp) async {
      final total = await _sizeOf(sftp, path);
      final file = await sftp.open(path);
      final progress = TransferProgressThrottle(onProgress, total);
      try {
        await for (final chunk in file.read()) {
          if (_cancelled) throw StateError('Transfer cancelled');
          output.add(chunk);
          progress.add(chunk.length);
        }
        progress.finish();
        return progress.copied;
      } finally {
        await file.close();
      }
    },
    // Never retried: bytes already written to the caller's sink would be duplicated.
    retryOnStaleConnection: false,
    timeout: _transferTimeout,
  );

  Future<int> _sizeOf(SftpClient sftp, String path) async {
    try {
      return (await sftp.stat(path)).size ?? 0;
    } catch (_) {
      return 0;
    }
  }

  @override
  void cancelActiveTransfers() {
    // The Kotlin had to close the caller-side stream first, because JSch could stay blocked inside
    // put()/get() after a channel disconnect. Dart's streaming loops check [_cancelled] on each
    // chunk and unwind on their own, so the flag is enough; the clients are then torn down.
    _cancelled = true;
    for (final sub in _activeTransfers.toList()) {
      sub.cancel();
    }
    _activeTransfers.clear();
    for (final client in _activeClients.toList()) {
      client.close();
    }
    _activeClients.clear();
  }

  @override
  void close() => cancelActiveTransfers();
}

/// A borrowed SSH connection, with the staleness and eviction hooks the SFTP retry policy needs.
///
/// This exists so `DartSshSftp` can express "only evict a *dropped* connection" without depending on
/// the pool's concrete types or on dartssh2 directly.
class SshConnectionLease {
  SshConnectionLease({
    required this.client,
    required bool Function() isStaleCheck,
    required void Function() onEvict,
    required void Function() onClose,
  }) : // Not initializing formals: Dart forbids underscore-prefixed named parameters.
       // ignore: prefer_initializing_formals
       _isStale = isStaleCheck,
       // ignore: prefer_initializing_formals
       _onEvict = onEvict,
       // ignore: prefer_initializing_formals
       _onClose = onClose;

  final SSHClient client;
  final bool Function() _isStale;
  final void Function() _onEvict;
  final void Function() _onClose;

  bool get isStale => _isStale();

  void evict() => _onEvict();

  void close() => _onClose();
}
