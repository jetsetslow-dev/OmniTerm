import 'dart:async';

import 'package:dartssh2/dartssh2.dart';

/// Bound channel/env/PTY/shell negotiation after authentication and host-key approval.
///
/// A timeout retires this dedicated client; it never retries a request that may have succeeded
/// remotely. An explicit optional-environment rejection may fall back within the same budget.
Future<SSHSession> openInteractiveShellChannel(
  SSHClient client,
  SSHPtyConfig pty, {
  Duration timeout = const Duration(seconds: 15),
}) async {
  var expired = false;
  Future<SSHSession> negotiate() async {
    try {
      return await client.shell(pty: pty, environment: const {'COLORTERM': 'truecolor'});
    } on SSHChannelRequestError {
      if (expired) rethrow;
      return client.shell(pty: pty);
    }
  }

  final pending = negotiate();
  // Future.timeout does not cancel the underlying future. Close a channel delivered after the
  // deadline too, and consume late failures without launching another optional fallback.
  unawaited(
    pending.then<void>((session) {
      if (expired) session.close();
    }, onError: (Object _, StackTrace _) {}),
  );
  return pending.timeout(
    timeout,
    onTimeout: () {
      expired = true;
      client.close();
      throw TimeoutException(
        'SSH shell channel did not open. Check the connection and retry.',
        timeout,
      );
    },
  );
}
