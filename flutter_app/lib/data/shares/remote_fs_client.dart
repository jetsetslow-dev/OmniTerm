import 'dart:async';
import 'dart:typed_data';

import 'package:intl/intl.dart';

import '../app_database.dart';
import '../kotlin_strings.dart';
import '../remote_models.dart';

/// Protocol-agnostic remote filesystem operations, ported from `data/shares/RemoteFsClient.kt`.
///
/// This is what lets the Shares browser and the cross-endpoint copy/paste engine behave identically
/// over SFTP, SMB, FTP and WebDAV. Paths are absolute and "/"-separated from the endpoint's root
/// (for SMB: the root of the connected share).
///
/// Implementations may cache an authenticated connection between calls; callers own the instance and
/// must [close] it when the browsing session or transfer ends.
///
/// Java's `InputStream`/`OutputStream` become Dart's `Stream<Uint8List>` and `StreamSink<List<int>>`,
/// which is also what removes the need for the Kotlin's manual read loops.
abstract class RemoteFsClient {
  /// Directory to start browsing at when the caller has no better idea.
  Future<String> home();

  Future<List<SftpFile>> list(String path);

  Future<void> mkdir(String path);

  Future<void> rename(String oldPath, String newPath, {bool isDirectory = false});

  Future<void> delete(String path, {required bool isDirectory});

  /// Stream the remote file into [output]; returns bytes copied. Does not close [output].
  Future<int> downloadTo(
    String path,
    StreamSink<List<int>> output, {
    void Function(int copied, int total)? onProgress,
  });

  /// Stream [input] to the remote path, overwriting. Does not close [input].
  Future<void> uploadStream(
    String path,
    Stream<List<int>> input,
    int totalBytes, {
    void Function(int copied, int total)? onProgress,
  });

  /// Whether this client can read and write a file's contents as text.
  ///
  /// Declared rather than assumed, and false by default. A client that cannot do this must make the
  /// editor say so, not offer a pencil that fails on tap (convention 4).
  bool get supportsTextEditing => false;

  /// Reads at most [maxBytes] of [path] as UTF-8, replacing malformed bytes.
  ///
  /// Only callable when [supportsTextEditing]; the default throws rather than returning empty,
  /// because an empty file and an unsupported operation must never look alike.
  Future<String> readText(String path, {int maxBytes = 512 * 1024}) =>
      throw UnsupportedError('This connection cannot read file contents.');

  /// Overwrites [path] with [content], returning the size the remote reports afterwards, or -1
  /// when it could not be read back.
  ///
  /// That return value is the whole point: it is what lets a save be *confirmed* rather than
  /// assumed. See `domain/file_edit.dart`.
  Future<int> writeText(String path, String content) =>
      throw UnsupportedError('This connection cannot write file contents.');

  /// Interrupt in-flight transfer I/O promptly; metadata-only clients may fall back to [close].
  void cancelActiveTransfers() => close();

  void close() {}
}

/// Thrown for protocols we can save/test but not browse (NFS, CUSTOM).
class UnsupportedShareProtocolException implements Exception {
  UnsupportedShareProtocolException(this.protocol);

  final String protocol;

  @override
  String toString() =>
      "Browsing $protocol shares isn't supported yet — SMB, FTP, SFTP and WebDAV are.";
}

/// Helpers for turning a saved share row into a browsing session.
abstract final class ShareClients {
  /// Directory the browser should open first; falls back to the client's [RemoteFsClient.home].
  static Future<String> startPath(NetworkShare share, RemoteFsClient client) async {
    final configured = _trimSlashes(share.sharePath);
    if (share.protocol.toUpperCase() == 'SMB') {
      // The first segment is the share name and is already consumed by the connection itself.
      final rest = configured.split('/').skip(1).where((s) => s.isNotEmpty).join('/');
      return '/$rest';
    }
    return configured.trim().isEmpty ? await client.home() : '/$configured';
  }

  static String? smbShareName(NetworkShare share) {
    final first = _trimSlashes(share.sharePath).split('/').firstOrNull;
    return (first == null || first.trim().isEmpty) ? null : first;
  }

  static String _trimSlashes(String value) {
    var s = value;
    while (s.startsWith('/')) {
      s = s.substring(1);
    }
    while (s.endsWith('/')) {
      s = s.substring(0, s.length - 1);
    }
    return s;
  }
}

/// Shared by the FTP, SMB and WebDAV listing parsers.
///
/// The Kotlin wrapped this in a `ThreadLocal` because `SimpleDateFormat` is not thread-safe and two
/// shares can be browsed at once on the IO dispatcher — a shared instance does not merely interleave,
/// it emits another thread's date or throws out of its number formatter. **Dart needs no such
/// guard:** an isolate is single-threaded, so one top-level formatter cannot be used concurrently.
final _fsModDateFormat = DateFormat('yyyy-MM-dd HH:mm', 'en_US');

String formatFsDate(int epochMillis) => epochMillis <= 0
    ? ''
    : _fsModDateFormat.format(DateTime.fromMillisecondsSinceEpoch(epochMillis));

/// Progress reporting throttled to every 64 KiB or 150 ms.
///
/// Ported from `copyWithProgress`. The cadence is the point: an unthrottled callback per chunk
/// floods the UI thread and makes a fast transfer *slower* than a throttled one.
class TransferProgressThrottle {
  TransferProgressThrottle(this.onProgress, this.totalBytes) {
    onProgress?.call(0, totalBytes);
  }

  static const _byteInterval = 64 * 1024;
  static const _timeInterval = Duration(milliseconds: 150);

  final void Function(int copied, int total)? onProgress;
  final int totalBytes;

  int _copied = 0;
  int _lastReportedBytes = 0;
  DateTime _lastReportedAt = DateTime.now();

  int get copied => _copied;

  void add(int bytes) {
    _copied += bytes;
    if (onProgress == null) return;
    final now = DateTime.now();
    if (_copied - _lastReportedBytes >= _byteInterval ||
        now.difference(_lastReportedAt) >= _timeInterval) {
      _lastReportedBytes = _copied;
      _lastReportedAt = now;
      onProgress!(_copied, totalBytes);
    }
  }

  /// Emits the final position. When the declared total was unknown (0), the observed count becomes
  /// the total so a completed transfer never renders as a partial one.
  void finish() => onProgress?.call(_copied, totalBytes > 0 ? totalBytes : _copied);
}

/// Pumps [input] into [output] with throttled progress, returning the bytes copied.
Future<int> copyWithProgress(
  Stream<List<int>> input,
  StreamSink<List<int>> output,
  int totalBytes, {
  void Function(int copied, int total)? onProgress,
}) async {
  final progress = TransferProgressThrottle(onProgress, totalBytes);
  await for (final chunk in input) {
    output.add(chunk);
    progress.add(chunk.length);
  }
  progress.finish();
  return progress.copied;
}

/// Convenience for implementations that build listings from raw byte counts.
Uint8List asBytes(List<int> data) => data is Uint8List ? data : Uint8List.fromList(data);
