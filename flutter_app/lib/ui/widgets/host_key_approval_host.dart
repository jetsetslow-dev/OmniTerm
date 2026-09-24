import 'dart:async';
import 'dart:collection';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../data/ssh/ssh_host_key_trust.dart';
import '../theme/colors.dart';
import '../theme/typography.dart';

/// The host-key approval prompt, ported from `HostKeyApprovalDialog` in `ui/ShellScreen.kt`.
///
/// Mounted once, above every screen, because the terminal is not the only thing that connects: the
/// monitor poller, SFTP, the fleet runner and a connection test all reach a first-contact host. A
/// prompt that only existed on the Shell would leave those paths failing closed with no way for the
/// user to say yes.
///
/// Without a registered handler `SshHostKeyTrust.check` returns `notIncluded` — it fails closed. So
/// this widget is what makes trust-on-first-use possible at all, and it is the only thing standing
/// between the user and a key they never looked at.
class HostKeyApprovalHost extends StatefulWidget {
  const HostKeyApprovalHost({super.key, required this.trust, required this.child});

  final SshHostKeyTrust trust;
  final Widget child;

  @override
  State<HostKeyApprovalHost> createState() => _HostKeyApprovalHostState();
}

class _HostKeyApprovalHostState extends State<HostKeyApprovalHost> {
  /// Requests wait their turn rather than stacking.
  ///
  /// Several hosts can be probed at once, and two dialogs over each other would let a user approve
  /// one host's fingerprint while reading another's. Each unanswered request still times out on its
  /// own deadline inside the trust store, so queueing can never hold a connection open forever.
  final Queue<HostKeyApprovalRequest> _queue = Queue();

  HostKeyApprovalRequest? _showing;

  @override
  void initState() {
    super.initState();
    widget.trust.registerApprovalHandler(this, _enqueue);
  }

  @override
  void dispose() {
    widget.trust.clearApprovalHandler(this);
    // Anything still queued is answered "no": leaving a completer hanging would hold a connection
    // attempt open until its timeout, and the honest answer for a prompt nobody can see is refusal.
    for (final pending in [..._queue, ?_showing]) {
      if (!pending.completer.isCompleted) pending.completer.complete(false);
    }
    _queue.clear();
    super.dispose();
  }

  void _enqueue(HostKeyApprovalRequest request) {
    _queue.add(request);
    _pump();
  }

  void _pump() {
    if (_showing != null || _queue.isEmpty || !mounted) return;
    final request = _queue.removeFirst();
    if (request.completer.isCompleted) {
      _pump();
      return;
    }
    _showing = request;
    // Pushing a route during the build phase is illegal, and a connection attempt can land there.
    // Outside a build the prompt is raised on a microtask instead of a post-frame callback: the
    // latter does not schedule a frame of its own, so a request arriving while the app is idle
    // would sit unshown until something else happened to repaint.
    if (SchedulerBinding.instance.schedulerPhase == SchedulerPhase.persistentCallbacks) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _present(request));
    } else {
      scheduleMicrotask(() => _present(request));
    }
  }

  Future<void> _present(HostKeyApprovalRequest request) async {
    if (!mounted) {
      if (!request.completer.isCompleted) request.completer.complete(false);
      return;
    }
    final approved = await showDialog<bool>(
      context: context,
      // Dismissing by tapping outside is a refusal, not an accident to be prevented. Making the
      // dialog inescapable would push a user who does not understand it toward the accept button.
      barrierDismissible: true,
      builder: (context) => HostKeyApprovalDialog(request: request),
    );
    if (!request.completer.isCompleted) request.completer.complete(approved ?? false);
    _showing = null;
    _pump();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// The dialog itself, separate so it can be shown — and tested — on its own.
class HostKeyApprovalDialog extends StatelessWidget {
  const HostKeyApprovalDialog({super.key, required this.request});

  final HostKeyApprovalRequest request;

  /// The file the server keeps this key type in, for the verification command.
  ///
  /// A user who does not already know how to check a fingerprint gets a command they can run rather
  /// than an instruction to "verify" that they will skip.
  static String hostKeyFile(String keyType) {
    final type = keyType.toLowerCase();
    if (type.contains('ed25519')) return 'ssh_host_ed25519_key.pub';
    if (type.contains('ecdsa')) return 'ssh_host_ecdsa_key.pub';
    if (type.contains('rsa')) return 'ssh_host_rsa_key.pub';
    return 'ssh_host_*_key.pub';
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final muted = TextStyle(fontSize: 12, color: scheme.onSurfaceVariant);

    return AlertDialog(
      key: const ValueKey('hostKey.dialog'),
      title: const Text('Trust this server?'),
      content: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('A new SSH host key was presented for:'),
            const SizedBox(height: 8),
            SelectionArea(
              child: Text(
                // Deliberately NOT routed through HostDisplay: the user is authenticating this
                // specific host against its fingerprint, so masking the identity would defeat the
                // security decision being asked of them.
                request.host,
                key: const ValueKey('hostKey.host'),
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
            const SizedBox(height: 8),
            Text('Key type: ${request.keyType}', style: muted),
            const SizedBox(height: 4),
            SelectionArea(
              child: Text(
                request.fingerprint,
                key: const ValueKey('hostKey.fingerprint'),
                style: TextStyle(
                  fontSize: 11,
                  fontFamily: OmniFonts.mono,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
            const SizedBox(height: 10),
            Text(
              'Verify this fingerprint matches the server before accepting. Accepting a key you '
              'have not checked is how a machine-in-the-middle succeeds.',
              style: muted,
            ),
            const SizedBox(height: 10),
            SelectionArea(
              child: Text(
                "How to verify: on the server's own screen (not over SSH), run:\n"
                'ssh-keygen -lf /etc/ssh/${hostKeyFile(request.keyType)}\n'
                'and check it prints the same SHA256 fingerprint.',
                key: const ValueKey('hostKey.howTo'),
                style: TextStyle(
                  fontSize: 11,
                  fontFamily: OmniFonts.mono,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        // Reject is first and Trust is not emphasised: the safe answer should be the easy one, and
        // this dialog appears at the moment a user is impatient to get connected.
        TextButton(
          key: const ValueKey('hostKey.reject'),
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Reject'),
        ),
        TextButton(
          key: const ValueKey('hostKey.trust'),
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('Trust & connect', style: TextStyle(color: OmniColors.amber)),
        ),
      ],
    );
  }
}
