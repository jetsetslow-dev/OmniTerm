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
import 'proxy_socket.dart';
import 'ssh_host_key_trust.dart';
import 'dartssh_sftp.dart';
import 'ssh_private_key.dart';
import 'channel_limiter.dart';
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

/// The agent to serve to the remote when the host has agent forwarding enabled, or null.
///
/// Kotlin's switch is `if (creds.agentForwarding) runCatching { setAgentForwarding(true) }`
/// (`JschSshTransport.kt:351`). The port carried `agentForwarding` from the host form through
/// `SshCredentials` and then never read it, so the switch stored a value and changed nothing.
///
/// Forwarding needs an agent to forward. There is no ssh-agent on a phone, so the app *is* the
/// agent: `SSHKeyPairAgent` answers identity and signing requests with the same key this connection
/// authenticated with, which is what makes the onward hop work without the private key ever being
/// copied to the server. With no key — a password host — there is nothing to serve, and offering an
/// empty agent would mean asking the server for a forwarding channel that could never sign
/// anything.
SSHAgentHandler? agentHandlerFor(SshCredentials creds, List<SSHKeyPair> identities) {
  if (!creds.agentForwarding || identities.isEmpty) return null;
  return SSHKeyPairAgent(identities);
}

class DartSshTransport implements SshTransport {
  DartSshTransport(this._trust, {this.printDebug});

  final SshHostKeyTrust _trust;
  final SSHPrintHandler? printDebug;

  /// Pooled clients for one-shot exec/execStream calls (never for interactive shells, which own
  /// their connection for its whole lifetime).
  late final SshSessionPool<SSHClient> _pool = SshSessionPool<SSHClient>(
    connect: _connect,
    isAlive: (client) => !client.isClosed,
    disconnect: (client) => client.close(),
  );

  bool _isJump(SshCredentials creds) =>
      creds.proxyType == 'ssh' && creds.proxyHost.trim().isNotEmpty && creds.proxyPort > 0;

  static const _proxyTypes = {'http', 'socks5'};

  bool _isProxied(SshCredentials creds) =>
      _proxyTypes.contains(creds.proxyType.toLowerCase()) &&
      creds.proxyHost.trim().isNotEmpty &&
      creds.proxyPort > 0;

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
  ///
  /// [forwardAgent] is opt-in per call rather than read from [creds] because Kotlin scopes agent
  /// forwarding to the interactive shell channel — `JschSshTransport.kt:351`, on the channel
  /// returned by `openChannel("shell")` — and dartssh2 applies it to *every* channel a client opens
  /// once `agentHandler` is set. Passing it here for pooled `exec` connections would put the
  /// monitoring commands behind a request the user only made for their shell.
  Future<SSHClient> _connect(
    SshCredentials creds, {
    void Function(String phase)? onPhaseChange,
    bool forwardAgent = false,
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
          printDebug: printDebug,
        );
        // Tunnel the target connection through the bastion, exactly as `ssh -J` does: the target's
        // own host key is still verified end-to-end below.
        socket = await jump.forwardLocal(creds.host, creds.port);
      } else if (_isProxied(creds)) {
        // Previously missing entirely: an `http` or `socks5` proxy was silently ignored and the app
        // connected straight to the target. That fails on exactly the hosts a proxy exists to
        // reach, and where it *does* succeed it has quietly bypassed a route the user chose
        // deliberately (§15.11).
        onPhaseChange?.call('Connecting through proxy…');
        socket = await connectThroughProxy(
          type: creds.proxyType,
          proxyHost: creds.proxyHost,
          proxyPort: creds.proxyPort,
          host: creds.host,
          port: creds.port,
          username: creds.proxyUser,
          password: creds.proxyPassword,
          timeout: _connectTimeout,
        );
      } else {
        socket = await SSHSocket.connect(creds.host, creds.port, timeout: _connectTimeout);
      }

      onPhaseChange?.call('Authenticating target…');
      final identities = _keyPairs(creds.privateKeyPem, creds.passphrase);
      final client = SSHClient(
        socket,
        username: creds.username,
        onPasswordRequest: () => creds.password,
        identities: identities,
        onVerifyHostKey: _verifier(creds.host, creds.port),
        keepAliveInterval: creds.keepAliveSeconds > 0
            ? Duration(seconds: creds.keepAliveSeconds)
            : null,
        agentHandler: forwardAgent ? agentHandlerFor(creds, identities) : null,
        compression: creds.compression,
        printDebug: printDebug,
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
  /// Opens a connection that belongs to the caller alone, outside the pool.
  ///
  /// Tunnels need this. A pooled client is shared and reaped when the last lease goes, which is
  /// exactly wrong for a forward that must stay up on its own terms — a port bound on this device
  /// has to keep working whether or not anything else is talking to that host.
  Future<SSHClient> openDedicatedClient(SshCredentials creds) => _connect(creds);

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

  /// Bounds how many channels this app opens at once on one connection; see [ChannelLimiter].
  final _channels = ChannelLimiter();

  Future<String> _execOnce(SshCredentials creds, String command, String? stdin) =>
      _channels.run(SshSessionPool.poolKey(creds), () => _execOnceUnlimited(creds, command, stdin));

  Future<String> _execOnceUnlimited(SshCredentials creds, String command, String? stdin) async {
    final lease = await _acquire(creds);
    SSHSession? session;
    try {
      session = await lease.client.execute(command);
      _writeStdin(session, stdin);

      final out = CappedTextBuffer(_execOutputMaxChars);
      final err = CappedTextBuffer(_execOutputMaxChars);
      await Future.wait([_drain(session.stdout, out), _drain(session.stderr, err)]);
      await session.done;

      final combined = StringBuffer(out.text());
      final errText = err.text();
      if (errText.trim().isNotEmpty) {
        if (combined.isNotEmpty && !combined.toString().endsWith('\n')) {
          combined.write('\n');
        }
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
    SshCancellationToken? cancellation,
    required Future<void> Function(String chunk) onChunk,
  }) async {
    try {
      return await _execStreamOnce(
        creds,
        command,
        stdin,
        onChunk,
        cancellation,
      ).timeout(_streamTimeout);
    } on TimeoutException {
      const error = 'SSH Error: command timed out';
      await onChunk(error);
      return error;
    } catch (e) {
      if (cancellation?.isCancelled ?? false) return 'Cancelled';
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
    SshCancellationToken? cancellation,
  ) => _channels.run(
    SshSessionPool.poolKey(creds),
    () => _execStreamOnceUnlimited(creds, command, stdin, onChunk, cancellation),
  );

  Future<String> _execStreamOnceUnlimited(
    SshCredentials creds,
    String command,
    String? stdin,
    Future<void> Function(String chunk) onChunk,
    SshCancellationToken? cancellation,
  ) async {
    final lease = await _acquire(creds);
    SSHSession? session;
    StreamSubscription<void>? cancellationSubscription;
    try {
      session = await lease.client.execute(command);
      if (cancellation?.isCancelled ?? false) {
        session.close();
        return 'Cancelled';
      }
      cancellationSubscription = cancellation?.onCancel.listen((_) => session?.close());
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
      await cancellationSubscription?.cancel();
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
    final detail = output.trim().isEmpty ? 'Command exited with status $exitCode' : output;
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

  /// Opens the shell channel, dropping the optional `COLORTERM` request if the server refuses it.
  ///
  /// A stock OpenSSH server accepts no environment variables unless they are listed in `AcceptEnv`
  /// and refuses the request outright, so asking for it as part of opening the channel meant **the
  /// terminal could not open on a default-configured server** — nearly all of them. Requested first
  /// because a server that allows it renders 24-bit colour correctly, then retried without, because
  /// a rejected optional request must never cost the user their shell (§15.9).
  Future<SSHSession> _openShellChannel(SSHClient client, SSHPtyConfig pty) async {
    try {
      return await client.shell(pty: pty, environment: const {'COLORTERM': 'truecolor'});
    } on SSHChannelRequestError {
      return client.shell(pty: pty);
    }
  }

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
      client = await _connect(
        creds,
        onPhaseChange: onPhaseChange,
        forwardAgent: creds.agentForwarding,
      );

      onPhaseChange?.call('Opening channel…');
      final pty = SSHPtyConfig(
        type: 'xterm-256color',
        width: cols < 1 ? 1 : cols,
        height: rows < 1 ? 1 : rows,
        pixelWidth: cols * 8,
        pixelHeight: rows * 16,
      );

      SSHSession session;
      try {
        session = await _openShellChannel(client, pty);
      } on SSHChannelRequestError {
        // The other optional request on this channel. Kotlin wraps agent forwarding in
        // `runCatching` (`JschSshTransport.kt:351`), so a server with `AllowAgentForwarding no`
        // costs the user nothing; here the agent is attached to the *client*, so honouring that
        // means reconnecting without it rather than retrying the channel.
        if (!creds.agentForwarding) rethrow;
        client.close();
        client = await _connect(creds, forwardAgent: false);
        session = await _openShellChannel(client, pty);
      }
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
