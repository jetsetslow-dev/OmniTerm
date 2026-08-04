/// Platform-agnostic SSH abstraction, ported from `data/ssh/SshTransport.kt`.
///
/// The Kotlin interface was written to be free of JSch (or any JVM-only) type, in anticipation of
/// becoming an `expect`/`actual` boundary under Compose Multiplatform. That foresight is what makes
/// this port cheap: the contract carries over unchanged, and only the implementation behind it
/// swaps from JSch to dartssh2.
///
/// Kotlin type mappings used throughout:
/// - `suspend fun` → `Future`
/// - `Flow<ByteArray>` → `Stream<Uint8List>`
/// - `StateFlow<T>` → [ValueListenable] (a current value plus change notifications, which is what
///   callers actually used it for)
library;

import 'package:flutter/foundation.dart';

/// Resolved connection credentials.
///
/// The view-model flattens a `Server` row (plus any referenced key/profile rows) into this, so the
/// transport never touches the database layer.
@immutable
class SshCredentials {
  const SshCredentials({
    required this.host,
    required this.port,
    required this.username,
    this.password,
    this.privateKeyPem,
    this.passphrase,
    this.proxyType = 'none',
    this.proxyHost = '',
    this.proxyPort = 0,
    this.proxyUser = '',
    this.proxyPassword = '',
    this.proxyKeyPem,
    this.keepAliveSeconds = 30,
    this.compression = false,
    this.agentForwarding = false,
  });

  final String host;
  final int port;
  final String username;
  final String? password;

  /// OpenSSH/PEM private key contents, when authenticating by key.
  final String? privateKeyPem;
  final String? passphrase;

  /// Proxy used to reach [host]: one of "none", "http", "socks5", "ssh" (jump host).
  final String proxyType;
  final String proxyHost;
  final int proxyPort;
  final String proxyUser;
  final String proxyPassword;

  /// OpenSSH/PEM private key contents for the jump host, when `proxyType == "ssh"`.
  final String? proxyKeyPem;

  /// SSH protocol keepalive interval. Zero disables protocol keepalives.
  final int keepAliveSeconds;

  /// Negotiate delayed zlib compression for bandwidth-constrained links.
  final bool compression;

  /// Forward the SSH authentication agent to the remote (OpenSSH `ForwardAgent yes` / `ssh -A`), so
  /// onward SSH hops from the remote can authenticate with the key we connected with — without
  /// copying the private key onto the server. Off by default (it grants the remote use of the key
  /// for the session's lifetime).
  final bool agentForwarding;

  /// Identity of the endpoint, used to key pooled connections and host-key trust.
  ///
  /// Deliberately excludes secrets: two credential sets differing only by password must still
  /// resolve to the same host for trust purposes, or a password change would silently look like a
  /// new, untrusted host.
  String get endpointKey => '$username@$host:$port';

  @override
  bool operator ==(Object other) =>
      other is SshCredentials &&
      other.host == host &&
      other.port == port &&
      other.username == username &&
      other.password == password &&
      other.privateKeyPem == privateKeyPem &&
      other.passphrase == passphrase &&
      other.proxyType == proxyType &&
      other.proxyHost == proxyHost &&
      other.proxyPort == proxyPort &&
      other.proxyUser == proxyUser &&
      other.proxyPassword == proxyPassword &&
      other.proxyKeyPem == proxyKeyPem &&
      other.keepAliveSeconds == keepAliveSeconds &&
      other.compression == compression &&
      other.agentForwarding == agentForwarding;

  @override
  int get hashCode => Object.hash(
    host,
    port,
    username,
    password,
    privateKeyPem,
    passphrase,
    proxyType,
    proxyHost,
    proxyPort,
    proxyUser,
    proxyPassword,
    proxyKeyPem,
    keepAliveSeconds,
    compression,
    agentForwarding,
  );

  /// Never interpolate credentials into logs or crash reports.
  @override
  String toString() => 'SshCredentials($endpointKey)';
}

/// Connection failed before/while establishing the shell or exec channel.
class SshConnectException implements Exception {
  SshConnectException(this.message, [this.cause]);

  final String message;
  final Object? cause;

  @override
  String toString() => 'SshConnectException: $message';
}

/// A live interactive shell channel.
abstract interface class TerminalSession {
  /// Raw bytes received from the remote PTY. Completes when the session closes.
  Stream<Uint8List> get output;

  /// `true` once the channel/session has been torn down (by either side).
  ValueListenable<bool> get closed;

  /// Remote shell exit status when known.
  ///
  /// Normal shell exits are usually `0`; a transport drop commonly leaves this as `-1`, which lets
  /// callers decide whether reconnect is appropriate.
  ValueListenable<int?> get exitStatus;

  /// `true` only when the remote deliberately ended the channel — i.e. the remote shell ran to
  /// completion (`exit`) and the server sent a genuine SSH channel-EOF.
  ///
  /// A network/transport drop (socket death, WiFi off) NEVER sets this: the remote never gets to
  /// send EOF. This is the unambiguous "the shell really exited" signal callers use to decide
  /// tear-down vs. reconnect, independent of the exit-status number (which can lag or be missing on
  /// a clean exit).
  ValueListenable<bool> get remoteExited;

  /// Send raw bytes (keystrokes / escape sequences) to the remote PTY.
  Future<void> write(Uint8List bytes);

  /// Inform the remote of a new terminal window size (SIGWINCH).
  Future<void> resize(int cols, int rows);

  /// Close the channel and underlying session. Idempotent.
  void close();
}

abstract interface class SshTransport {
  /// Run a single command on a throwaway exec channel and return its combined output.
  ///
  /// [stdin] is written to the remote command's standard input and never appears in the command
  /// string itself — used to feed `sudo -S` its password without the password landing in `ps`
  /// output, shell audit logs, or sshd debug logs.
  Future<String> exec(SshCredentials creds, String command, {String? stdin});

  /// Run a command and stream its output incrementally (stdout + stderr merged) by invoking
  /// [onChunk] for each read burst until the channel closes.
  ///
  /// Useful for long-running docker commands (pull, update) where the caller wants to show progress
  /// in real time. The full combined output is also returned for convenience once the command
  /// finishes. [stdin] behaves as in [exec].
  Future<String> execStream(
    SshCredentials creds,
    String command, {
    String? stdin,
    required Future<void> Function(String chunk) onChunk,
  });

  /// Actually authenticate against the host: open a session and connect with the given credentials,
  /// then tear it down.
  ///
  /// Returns null on success, or a human-readable error (e.g. "Auth fail", "Connection refused") on
  /// failure. This is a *real* connectivity + credential test, not a TCP ping.
  Future<String?> testConnection(SshCredentials creds);

  /// Open a persistent interactive shell backed by a PTY.
  ///
  /// The returned [TerminalSession] streams raw bytes from the remote and accepts raw keystrokes —
  /// this is what makes `cd`, env state, tab-completion, arrow-key history and full-screen apps
  /// work. [onPhaseChange] is called with human-readable progress strings during connection setup.
  Future<TerminalSession> openShell(
    SshCredentials creds,
    int cols,
    int rows, {
    void Function(String phase)? onPhaseChange,
  });

  /// Release any pooled/cached connections held by the transport. Idempotent.
  void shutdown();

  /// Forget cached authenticated transport state for one credential set.
  void forgetCredentials(SshCredentials creds);
}
