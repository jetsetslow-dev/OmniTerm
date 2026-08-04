import 'dart:async';

import 'package:flutter/services.dart';

import '../remote_models.dart';
import 'remote_fs_client.dart';

/// Everything needed to reach one SMB share.
class SmbEndpoint {
  const SmbEndpoint({
    required this.host,
    required this.port,
    required this.shareName,
    this.domain = '',
    this.username = '',
    this.password = '',
    this.anonymous = false,
  });

  final String host;
  final int port;
  final String shareName;
  final String domain;
  final String username;
  final String password;
  final bool anonymous;

  Map<String, Object?> toArguments() => {
        'host': host,
        'port': port,
        'share': shareName,
        'domain': domain,
        'username': username,
        'password': password,
        'anonymous': anonymous,
      };

  /// Identifies the connection without carrying the secret, for logs and error text.
  String get label => '\\\\$host\\$shareName';
}

/// SMB2/3 through a platform-native client, behind the ported [RemoteFsClient] seam (§7.1).
///
/// **Why native rather than Dart.** The only pub package for SMB pins a `pointycastle` major that
/// `dartssh2` cannot coexist with, and it is an unmaintained implementation of a large,
/// attacker-reachable wire protocol. Under requirement 12 the right answer is a mature, maintained,
/// widely-audited implementation — smbj on Android — not an unmaintained one and certainly not a
/// hand-rolled SMB2/3 parser written under migration pressure.
///
/// The whole SMB surface is confined to this class and the platform folders. The Shares browser and
/// the cross-endpoint copy engine see only [RemoteFsClient] and cannot tell the difference.
class PlatformSmbClient extends RemoteFsClient {
  PlatformSmbClient(
    this.endpoint, {
    MethodChannel? channel,
    EventChannel? transfers,
  })  : _channel = channel ?? const MethodChannel(methodChannelName),
        _transfers = transfers ?? const EventChannel(eventChannelName);

  static const methodChannelName = 'omniterm/smb';
  static const eventChannelName = 'omniterm/smb/transfers';

  final SmbEndpoint endpoint;
  final MethodChannel _channel;
  final EventChannel _transfers;

  /// The native session this client owns, once opened.
  ///
  /// A handle rather than a global: two shares can be browsed at once, and a copy between them is
  /// the whole point of the cross-endpoint engine.
  String? _sessionId;

  bool _closed = false;

  /// Whether the running platform has an SMB implementation at all.
  ///
  /// Asked rather than assumed so the Shares screen can say "SMB is not available on this platform"
  /// instead of presenting a share that fails on first tap (Convention 4).
  Future<bool> isSupported() async {
    try {
      return await _channel.invokeMethod<bool>('isSupported') ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  Future<String> _session() async {
    if (_closed) throw SmbException('This share connection has been closed.');
    final existing = _sessionId;
    if (existing != null) return existing;
    // Connecting is several round-trips — negotiate, session setup, tree connect — so the native
    // side keeps it warm for the life of this client, exactly as the Kotlin did.
    final id = await _invoke<String>('connect', endpoint.toArguments());
    _sessionId = id;
    return id;
  }

  Future<T> _invoke<T>(String method, [Map<String, Object?> arguments = const {}]) async {
    try {
      final result = await _channel.invokeMethod<T>(method, arguments);
      if (result == null) {
        throw SmbException('The SMB client returned nothing for "$method".');
      }
      return result;
    } on MissingPluginException {
      throw SmbException(
        'SMB is not available on this platform. Use SFTP, FTP or WebDAV for ${endpoint.label}.',
      );
    } on PlatformException catch (e) {
      // The native side classifies: a dead transport drops the cached session so the next call
      // reconnects, while an access-denied or not-found must surface as-is rather than burning a
      // working connection.
      if (e.code == 'transport') _sessionId = null;
      throw SmbException(e.message ?? 'SMB error (${e.code}) on ${endpoint.label}.', code: e.code);
    }
  }

  Future<void> _call(String method, [Map<String, Object?> arguments = const {}]) async {
    final session = await _session();
    await _invoke<bool>(method, {'session': session, ...arguments});
  }

  @override
  Future<String> home() async => '/';

  @override
  Future<List<SftpFile>> list(String path) async {
    final session = await _session();
    final rows = await _invoke<List<Object?>>('list', {'session': session, 'path': path});
    return rows.whereType<Map<Object?, Object?>>().map(_toFile).toList();
  }

  static SftpFile _toFile(Map<Object?, Object?> row) {
    final isDirectory = row['isDirectory'] == true;
    final modSeconds = (row['modTimeSeconds'] as num?)?.toInt() ?? 0;
    return SftpFile(
      name: (row['name'] as String?) ?? '',
      isDirectory: isDirectory,
      // A directory's "size" on SMB is an implementation detail, not a byte count. Reporting zero
      // matches every other client and stops the UI showing a meaningless number.
      size: isDirectory ? 0 : (row['size'] as num?)?.toInt() ?? 0,
      modDate: formatFsDate(modSeconds * 1000),
      modTimeSeconds: modSeconds,
    );
  }

  @override
  Future<void> mkdir(String path) => _call('mkdir', {'path': path});

  @override
  Future<void> rename(String oldPath, String newPath, {bool isDirectory = false}) =>
      _call('rename', {'from': oldPath, 'to': newPath, 'isDirectory': isDirectory});

  @override
  Future<void> delete(String path, {required bool isDirectory}) =>
      _call('delete', {'path': path, 'isDirectory': isDirectory});

  @override
  Future<int> downloadTo(
    String path,
    StreamSink<List<int>> output, {
    void Function(int copied, int total)? onProgress,
  }) async {
    final session = await _session();
    final transferId = _nextTransferId();
    var copied = 0;
    var total = 0;

    // Chunks arrive on an event channel rather than as one method-call return, so a large file is
    // never materialised whole in memory on either side of the boundary.
    final completer = Completer<int>();
    late StreamSubscription<dynamic> subscription;
    subscription = _transfers.receiveBroadcastStream({
      'session': session,
      'transfer': transferId,
      'op': 'download',
      'path': path,
    }).listen(
      (event) {
        final message = event as Map<Object?, Object?>;
        if (message['transfer'] != transferId) return;
        final bytes = message['bytes'];
        if (bytes is Uint8List) {
          output.add(bytes);
          copied += bytes.length;
          total = (message['total'] as num?)?.toInt() ?? total;
          onProgress?.call(copied, total);
        }
        if (message['done'] == true && !completer.isCompleted) completer.complete(copied);
      },
      onError: (Object error) {
        if (completer.isCompleted) return;
        // A dropped transport mid-download is never retried: the caller's sink already holds a
        // partial file, and re-running would silently duplicate the bytes already written.
        _sessionId = null;
        completer.completeError(
          SmbException(error is PlatformException
              ? error.message ?? 'The download failed.'
              : 'The download failed: $error'),
        );
      },
      onDone: () {
        if (!completer.isCompleted) {
          completer.completeError(
            SmbException('The download ended before the file was complete.'),
          );
        }
      },
    );

    _active.add(subscription);
    try {
      return await completer.future;
    } finally {
      _active.remove(subscription);
      await subscription.cancel();
    }
  }

  @override
  Future<void> uploadStream(
    String path,
    Stream<List<int>> input,
    int totalBytes, {
    void Function(int copied, int total)? onProgress,
  }) async {
    final session = await _session();
    final transferId = _nextTransferId();
    await _invoke<bool>('uploadBegin', {
      'session': session,
      'transfer': transferId,
      'path': path,
      'total': totalBytes,
    });

    var copied = 0;
    try {
      await for (final chunk in input) {
        if (_closed) throw SmbException('The upload was cancelled.');
        await _invoke<bool>('uploadChunk', {
          'session': session,
          'transfer': transferId,
          'bytes': Uint8List.fromList(chunk),
        });
        copied += chunk.length;
        onProgress?.call(copied, totalBytes);
      }
      await _invoke<bool>('uploadEnd', {'session': session, 'transfer': transferId});
    } catch (_) {
      // Abandoning tells the native side to close the handle. Without it a failed upload leaves a
      // truncated file locked open on the share until the session drops.
      await _abandon(session, transferId);
      rethrow;
    }
  }

  Future<void> _abandon(String session, String transferId) async {
    try {
      await _channel.invokeMethod<bool>('uploadAbort', {
        'session': session,
        'transfer': transferId,
      });
    } catch (_) {
      // The original failure is what the caller needs to hear about.
    }
  }

  final Set<StreamSubscription<dynamic>> _active = {};

  var _transferCounter = 0;

  String _nextTransferId() => '${identityHashCode(this)}-${_transferCounter++}';

  @override
  void cancelActiveTransfers() {
    for (final subscription in _active.toList()) {
      unawaited(subscription.cancel());
    }
    _active.clear();
    close();
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    final session = _sessionId;
    _sessionId = null;
    if (session == null) return;
    // Fire-and-forget: `close` is synchronous by contract, and a share that fails to disconnect
    // cleanly is not something the caller can act on.
    unawaited(
      _channel.invokeMethod<bool>('disconnect', {'session': session}).catchError((Object _) => false),
    );
  }
}

/// An SMB failure with the native side's classification attached.
class SmbException implements Exception {
  SmbException(this.message, {this.code});

  final String message;

  /// `transport` for a dead connection, otherwise the protocol status the server returned.
  final String? code;

  @override
  String toString() => message;
}
