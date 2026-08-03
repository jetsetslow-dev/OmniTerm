/// dartssh2-backed [SshTransport], ported from `data/ssh/JschSshTransport.kt`.
///
/// ## What the rewrite removes
///
/// JSch's channel streams are **blocking**, so the Kotlin needed a dedicated daemon thread per
/// shell doing `shellIn.read(buf)` and funnelling bytes into a bounded coroutine `Channel` to get
/// backpressure. dartssh2 exposes `Stream<Uint8List>` directly and Dart streams already carry
/// backpressure through pause/resume, so the reader thread, the bounded channel and the
/// `trySendBlocking` dance all disappear — roughly a third of the original file.
///
/// The same applies to `exec`: the Kotlin polled `available()` in a 50 ms loop because a blocking
/// read could not be cancelled. Here stdout and stderr are just streams to await.
///
/// What is *kept* is the behaviour that was hard-won: at-most-once semantics for commands (a failed
/// call is never retried, because the request may already have reached the server), the
/// exit-status/EOF classification that distinguishes a real `exit` from a network drop, and the
/// rule that secrets travel via channel stdin and never inside the command string.
library;

import 'dart:async';
import 'dart:convert';
import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';

import '../term/utf8_stream_decoder.dart';
import 'capped_text_buffer.dart';
import 'ssh_host_key_trust.dart';
import 'dartssh_sftp.dart';
import 'ssh_private_key.dart';
import 'ssh_session_pool.dart';
import 'ssh_transport.dart';
import 'terminal_close.dart';

const _execOutputMaxChars = 240000;

const _connectTimeout = Duration(seconds: 15);
const _testCommandTimeout = Duration(seconds: 10);
const _execTimeout = Duration(minutes: 2);
const _streamTimeout = Duration(minutes: 30);

/// Raised when a host key is unknown/declined or has changed. Carried out of the connect path so
/// the UI can distinguish "you must approve this host" from an ordinary auth failure.
class SshHostKeyException implements Exception {
  SshHostKeyException(this.message, this.verdict);

  final String message;
  final HostKeyVerdict verdict;

  @override
  String toString() => message;
}

class DartSshTransport implements SshTransport {
  DartSshTransport(this._trust);

  final SshHostKeyTrust _trust;

  /// Pooled clients for one-shot exec/execStream calls (never for interactive shells, which own
  /// their connection for its whole lifetime).
  late final SshSessionPool<SSHClient> _pool = SshSessionPool<SSHClient>(
    connect: _connect,
    isAlive: (client) => !client.isClosed,
    disconnect: (client) => client.close(),
  );

  bool _isJump(SshCredentials creds) =>
      creds.proxyType == 'ssh' && creds.proxyHost.trim().isNotEmpty && creds.proxyPort > 0;

  // ── connection construction ────────────────────────────────────────────────

  /// Builds the host-key verifier for one endpoint.
  ///
  /// dartssh2 passes only `(type, fingerprint)`, so host and port are closed over here. Returning
  /// false aborts the handshake, which is what a declined or changed key must do.
  Future<bool> Function(String, Uint8List) _verifier(String host, int port) {
    return (String type, Uint8List fingerprint) async {
      final verdict = await _trust.check(
        host: host,
        port: port,
        keyType: type,
        fingerprint: SshHostKeyTrust.decodeHandlerFingerprint(fingerprint),
      );
      return verdict == HostKeyVerdict.ok;
    };
  }

  List<SSHKeyPair> _keyPairs(String? pem, String? passphrase) {
    if (pem == null || pem.trim().isEmpty) return const [];
    return parsePrivateKey(pem, passphrase: passphrase);
  }

  /// Opens a client to [creds], routing through a jump host or proxy when configured.
  Future<SSHClient> _connect(
    SshCredentials creds, {
    void Function(String phase)? onPhaseChange,
  }) async {
    SSHClient? jump;
    try {
      final SSHSocket socket;
      if (_isJump(creds)) {
        onPhaseChange?.call('Authenticating bastion…');
        jump = SSHClient(
          await SSHSocket.connect(creds.proxyHost, creds.proxyPort, timeout: _connectTimeout),
          username: creds.proxyUser,
          onPasswordRequest: () => creds.proxyPassword,
          // The passphrase field belongs to the *target* key, not the bastion's — feeding it here
          // would try to decrypt the jump key with the wrong secret. Matches the Kotlin, which
          // passed null. (Encrypted jump keys are consequently unsupported, as before.)
          identities: _keyPairs(creds.proxyKeyPem, null),
          onVerifyHostKey: _verifier(creds.proxyHost, creds.proxyPort),
        );
        // Tunnel the target connection through the bastion, exactly as `ssh -J` does: the target's
        // own host key is still verified end-to-end below.
        socket = await jump.forwardLocal(creds.host, creds.port);
      } else {
        socket = await SSHSocket.connect(creds.host, creds.port, timeout: _connectTimeout);
      }

      onPhaseChange?.call('Authenticating target…');
      final client = SSHClient(
        socket,
        username: creds.username,
        onPasswordRequest: () => creds.password,
        identities: _keyPairs(creds.privateKeyPem, creds.passphrase),
        onVerifyHostKey: _verifier(creds.host, creds.port),
        keepAliveInterval:
            creds.keepAliveSeconds > 0 ? Duration(seconds: creds.keepAliveSeconds) : null,
      );
      await client.authenticated;

      // The bastion must outlive the target client, so tie its teardown to the target's.
      if (jump != null) {
        final bastion = jump;
        unawaited(client.done.whenComplete(bastion.close));
      }
      return client;
    } catch (e) {
      jump?.close();
      rethrow;
    }
  }

  /// Borrow a connection for a one-shot command.
  ///
  /// Jump-host connections are never pooled: the pool has nowhere to hold the paired bastion, so
  /// those get a dedicated connection torn down by the caller.
  Future<SshLease<SSHClient>> _acquire(SshCredentials creds) async {
    if (_isJump(creds)) {
      final client = await _connect(creds);
      return SshLease.unpooled(client, () => client.close());
    }
    return _pool.acquire(creds);
  }

  // ── exec ───────────────────────────────────────────────────────────────────

  @override
  Future<String> exec(SshCredentials creds, String command, {String? stdin}) async {
    try {
      return await _execOnce(creds, command, stdin).timeout(_execTimeout);
    } on TimeoutException {
      return 'SSH Error: command timed out';
    } catch (e) {
      // The request may already have reached the server. The suspect connection was already
      // evicted at the point of failure; never retry an arbitrary command and risk executing a
      // mutation twice.
      return 'SSH Error: ${_describe(e)}';
    }
  }

  Future<String> _execOnce(SshCredentials creds, String command, String? stdin) async {
    final lease = await _acquire(creds);
    SSHSession? session;
    try {
      session = await lease.client.execute(command);
      _writeStdin(session, stdin);

      final out = CappedTextBuffer(_execOutputMaxChars);
      final err = CappedTextBuffer(_execOutputMaxChars);
      await Future.wait([
        _drain(session.stdout, out),
        _drain(session.stderr, err),
      ]);
      await session.done;

      final combined = StringBuffer(out.text());
      final errText = err.text();
      if (errText.trim().isNotEmpty) {
        if (combined.isNotEmpty && !combined.toString().endsWith('\n')) combined.write('\n');
        combined.write(errText);
      }
      return _withExitStatus(combined.toString(), session.exitCode);
    } catch (_) {
      // Only this connection is suspect; passing it as the suspect stops a slow failure from
      // evicting a healthy replacement that has already taken its place.
      _pool.evict(creds, lease.client);
      rethrow;
    } finally {
      session?.close();
      lease.close();
    }
  }

  @override
  Future<String> execStream(
    SshCredentials creds,
    String command, {
    String? stdin,
    required Future<void> Function(String chunk) onChunk,
  }) async {
    try {
      return await _execStreamOnce(creds, command, stdin, onChunk).timeout(_streamTimeout);
    } on TimeoutException {
      const error = 'SSH Error: command timed out';
      await onChunk(error);
      return error;
    } catch (e) {
      // Zero output does not mean the remote command did not run. Preserve at-most-once semantics
      // for destructive streaming actions too.
      final message = 'SSH Error: ${_describe(e)}';
      await onChunk(message);
      return message;
    }
  }

  Future<String> _execStreamOnce(
    SshCredentials creds,
    String command,
    String? stdin,
    Future<void> Function(String chunk) onChunk,
  ) async {
    final lease = await _acquire(creds);
    SSHSession? session;
    try {
      session = await lease.client.execute(command);
      _writeStdin(session, stdin);

      final accumulated = CappedTextBuffer(_execOutputMaxChars);
      // stdout and stderr are decoded separately: a multi-byte character split across a read
      // boundary on one stream must not be reassembled using bytes from the other.
      await Future.wait([
        _pump(session.stdout, accumulated, onChunk),
        _pump(session.stderr, accumulated, onChunk),
      ]);
      await session.done;

      return _withExitStatus(accumulated.text(), session.exitCode);
    } catch (_) {
      _pool.evict(creds, lease.client);
      rethrow;
    } finally {
      session?.close();
      lease.close();
    }
  }

  /// Secrets (sudo passwords) travel via the channel's stdin, never the command string — so they
  /// never land in `ps` output, shell audit logs, or sshd debug logs.
  void _writeStdin(SSHSession session, String? stdin) {
    if (stdin == null) return;
    session.write(Uint8List.fromList(utf8.encode(stdin)));
    // EOF on stdin, so a command that reads until EOF (`sudo -S`, `cat`) actually proceeds instead
    // of blocking forever on a channel we are never going to write to again.
    session.stdin.close();
  }

  Future<void> _drain(Stream<Uint8List> stream, CappedTextBuffer sink) async {
    final decoder = Utf8StreamDecoder();
    await for (final chunk in stream) {
      sink.append(decoder.decode(chunk));
    }
    sink.append(decoder.finish());
  }

  Future<void> _pump(
    Stream<Uint8List> stream,
    CappedTextBuffer sink,
    Future<void> Function(String) onChunk,
  ) async {
    final decoder = Utf8StreamDecoder();
    await for (final bytes in stream) {
      final chunk = decoder.decode(bytes);
      if (chunk.isEmpty) continue;
      sink.append(chunk);
      await onChunk(chunk);
    }
    final tail = decoder.finish();
    if (tail.isNotEmpty) {
      sink.append(tail);
      await onChunk(tail);
    }
  }

  /// Formats the result the way the screens expect: raw output on success, and a prefixed error
  /// carrying the status plus whatever the command managed to say on failure.
  static String _withExitStatus(String output, int? exitCode) {
    if (exitCode == 0) return output;
    final detail =
        output.trim().isEmpty ? 'Command exited with status $exitCode' : output;
    return 'SSH Error: command failed ($exitCode): $detail';
  }

  static String _describe(Object e) {
    if (e is InvalidPrivateKeyException) return e.message;
    if (e is SshHostKeyException) return e.message;
    if (e is SSHAuthAbortError) return e.message;
    if (e is SSHAuthFailError) return e.message;
    if (e is SSHError) return e.toString();
    return e.toString();
  }

  // ── connection test ────────────────────────────────────────────────────────

  @override
  Future<String?> testConnection(SshCredentials creds) async {
    SSHClient? client;
    try {
      client = await _connect(creds);
      // Prove we can actually run something, not just complete the handshake.
      final session = await client.execute('true');
      try {
        await session.done.timeout(_testCommandTimeout);
        if (session.exitCode != 0) {
          return 'Test command exited with status ${session.exitCode}';
        }
      } finally {
        session.close();
      }
      return null;
    } catch (e) {
      return _describe(e);
    } finally {
      client?.close();
    }
  }

  // ── interactive shell ──────────────────────────────────────────────────────

  @override
  Future<TerminalSession> openShell(
    SshCredentials creds,
    int cols,
    int rows, {
    void Function(String phase)? onPhaseChange,
  }) async {
    SSHClient? client;
    try {
      onPhaseChange?.call('Resolving target…');
      client = await _connect(creds, onPhaseChange: onPhaseChange);

      onPhaseChange?.call('Opening channel…');
      final session = await client.shell(
        pty: SSHPtyConfig(
          type: 'xterm-256color',
          width: cols < 1 ? 1 : cols,
          height: rows < 1 ? 1 : rows,
          pixelWidth: cols * 8,
          pixelHeight: rows * 16,
        ),
        environment: const {'COLORTERM': 'truecolor'},
      );
      return _DartSshTerminalSession(client, session);
    } catch (e) {
      client?.close();
      if (e is SshHostKeyException) rethrow;
      throw SshConnectException(_describe(e), e);
    }
  }

  /// Builds an SFTP client that borrows from this transport's connection pool.
  ///
  /// The SFTP client owns no connection policy of its own: it receives a lease with staleness and
  /// eviction hooks, which is what lets it implement "retry once on a *dropped* connection, never on
  /// a logical error" without knowing about the pool or dartssh2's client type.
  DartSshSftp sftp(SshCredentials creds) => DartSshSftp(creds, _lease);

  Future<SshConnectionLease> _lease(SshCredentials creds) async {
    final lease = await _acquire(creds);
    return SshConnectionLease(
      client: lease.client,
      isStaleCheck: () => lease.client.isClosed,
      onEvict: () => _pool.evict(creds, lease.client),
      onClose: lease.close,
    );
  }

  @override
  void shutdown() => _pool.closeAll();

  @override
  void forgetCredentials(SshCredentials creds) => _pool.evict(creds);
}

/// One persistent PTY shell over a dartssh2 session.
class _DartSshTerminalSession implements TerminalSession {
  _DartSshTerminalSession(this._client, this._session) {
    _outputSub = _session.stdout.listen(
      _outputController.add,
      onError: (_) {
        // A transport error is not a remote exit: leave [_remoteEof] false so the classifier treats
        // it as a drop and the caller reconnects.
        close();
      },
      onDone: () {
        _remoteEof = true;
        close();
      },
    );
    // A PTY merges stderr into stdout, but a server may still send some; surface it rather than
    // silently dropping terminal output.
    _errorSub = _session.stderr.listen(_outputController.add, onError: (_) {});
  }

  final SSHClient _client;
  final SSHSession _session;

  final StreamController<Uint8List> _outputController = StreamController<Uint8List>();
  StreamSubscription<Uint8List>? _outputSub;
  StreamSubscription<Uint8List>? _errorSub;

  final ValueNotifier<bool> _closed = ValueNotifier(false);
  final ValueNotifier<int?> _exitStatus = ValueNotifier(null);
  final ValueNotifier<bool> _remoteExited = ValueNotifier(false);

  /// True when the stream ended because the remote closed it gracefully, as opposed to us closing
  /// the channel or the connection dropping mid-read.
  bool _remoteEof = false;

  @override
  Stream<Uint8List> get output => _outputController.stream;

  @override
  ValueListenable<bool> get closed => _closed;

  @override
  ValueListenable<int?> get exitStatus => _exitStatus;

  @override
  ValueListenable<bool> get remoteExited => _remoteExited;

  @override
  Future<void> write(Uint8List bytes) async {
    if (_closed.value) return;
    try {
      _session.write(bytes);
    } catch (_) {
      close();
    }
  }

  @override
  Future<void> resize(int cols, int rows) async {
    if (_closed.value) return;
    try {
      _session.resizeTerminal(cols < 1 ? 1 : cols, rows < 1 ? 1 : rows, cols * 8, rows * 16);
    } catch (_) {
      // benign — remote may not honour resize
    }
  }

  @override
  void close() {
    if (_closed.value) return;
    _closed.value = true;

    // dartssh2 surfaces the exit status on the session once the server sends it. Unlike JSch, there
    // is no lagging status message to poll for: `stdout` completing and `exitCode` being set are
    // both driven by the same channel-close handling.
    final classification = classifyTerminalClose(
      remoteEof: _remoteEof,
      channelIsEof: _remoteEof,
      sessionConnected: !_client.isClosed,
      exitStatus: _session.exitCode,
    );
    _remoteExited.value = classification.remoteExited;
    _exitStatus.value = classification.exitStatus;

    _outputSub?.cancel();
    _errorSub?.cancel();
    _session.close();
    _client.close();
    if (!_outputController.isClosed) _outputController.close();
  }
}
