import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../data/app_database.dart';
import '../../domain/host_display.dart';
import '../theme/colors.dart';
import '../theme/typography.dart';
import '../view_model/shell_view_model.dart';

/// The questions [ShellViewModel.connect] can stop and ask before opening a terminal.
///
/// Two of them, ported from `TmuxInstallDialog` and `OfflineConnectDialog` (`ui/AppUi.kt:617`,
/// `:671`): "this host looks offline, connect anyway?" and "this host wants persistent sessions but
/// has no tmux".
///
/// Mounted above every screen rather than on the Shell, and one widget rather than two, because both
/// are asked by the same view model at the same point. A host is connected from the host list, the
/// Infra tab's container shell, a quick-connect sheet, a shortcut and a quick action — a prompt that
/// existed only on the Shell would leave those paths refusing to connect with nothing on screen
/// explaining why.
class ConnectionPromptHost extends StatefulWidget {
  const ConnectionPromptHost({super.key, required this.child});

  final Widget child;

  @override
  State<ConnectionPromptHost> createState() => _ConnectionPromptHostState();
}

class _ConnectionPromptHostState extends State<ConnectionPromptHost> {
  ShellViewModel? _shell;
  bool _showing = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final shell = context.read<ShellViewModel>();
    if (identical(shell, _shell)) return;
    _shell?.removeListener(_onShellChanged);
    _shell = shell..addListener(_onShellChanged);
  }

  @override
  void dispose() {
    _shell?.removeListener(_onShellChanged);
    super.dispose();
  }

  /// Which prompt, if any, the view model is currently asking.
  _Prompt? get _pending {
    final shell = _shell;
    if (shell == null) return null;
    if (shell.offlineConnectPromptServer != null) return _Prompt.offline;
    if (shell.tmuxPromptServer != null) return _Prompt.tmux;
    return null;
  }

  void _onShellChanged() {
    if (!mounted) return;
    final pending = _pending;
    if (_showing) {
      // Whichever action resolved it — installed and connected, or connected plain — clears the
      // pending host. Closed from here rather than from the dialog's own builder: a builder that
      // schedules a pop re-schedules it on every rebuild, and the frame loop never goes quiet.
      if (pending == null) {
        _showing = false;
        Navigator.of(context, rootNavigator: true).pop();
      }
      return;
    }
    if (pending == null) return;
    _showing = true;
    // Deferred: this runs from a notification, and pushing a route during one is not allowed.
    WidgetsBinding.instance.addPostFrameCallback((_) => _show());
  }

  Future<void> _show() async {
    final shell = _shell;
    if (!mounted || shell == null) {
      _showing = false;
      return;
    }
    await showDialog<void>(
      context: context,
      // Not dismissible while an install is running: tearing the dialog down mid-install would
      // leave the output nowhere to go and the user unsure whether it finished.
      barrierDismissible: false,
      builder: (_) => _ConnectionPromptDialog(shell: shell),
    );
    _showing = false;
    // The user closed it without deciding — clear the pending host so a later connection can prompt
    // again rather than being swallowed by stale state.
    if (mounted && shell.tmuxPromptServer != null) shell.dismissTmuxPrompt();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

enum _Prompt { offline, tmux }

class _ConnectionPromptDialog extends StatelessWidget {
  const _ConnectionPromptDialog({required this.shell});

  final ShellViewModel shell;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: shell,
      builder: (context, _) {
        final offline = shell.offlineConnectPromptServer;
        if (offline != null) return _offlineDialog(context, offline);

        final server = shell.tmuxPromptServer;
        // The host pops this route when the prompt clears; until that frame lands there is simply
        // nothing to draw.
        if (server == null) return const SizedBox.shrink();

        final installing = shell.tmuxInstalling;
        final output = shell.tmuxInstallOutput;
        return AlertDialog(
          key: const ValueKey('tmux.install.dialog'),
          title: Text('Install tmux on ${server.name}?'),
          content: SizedBox(
            width: double.maxFinite,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  "This host is set to use persistent sessions, but tmux isn't installed. tmux lets "
                  'sessions survive network drops and keeps long-running commands going after a '
                  'reconnect.',
                  style: TextStyle(fontSize: 13),
                ),
                const SizedBox(height: 8),
                Text(
                  'Install runs the appropriate package-manager command on this host (using your '
                  'sudo password if set). Connecting without tmux opens a normal, non-resumable '
                  'shell.',
                  style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
                if (output != null) ...[
                  const SizedBox(height: 8),
                  Container(
                    width: double.infinity,
                    constraints: const BoxConstraints(maxHeight: 180),
                    padding: const EdgeInsets.all(8),
                    color: Theme.of(context).colorScheme.surfaceContainerHighest,
                    child: SingleChildScrollView(
                      child: SelectableText(
                        // An empty string means the command has been sent and nothing has come back
                        // yet; a blank box would read as the install having done nothing.
                        output.isEmpty ? 'Starting…' : output,
                        key: const ValueKey('tmux.install.output'),
                        style: const TextStyle(fontFamily: OmniFonts.mono, fontSize: 11),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              key: const ValueKey('tmux.install.cancel'),
              onPressed: installing ? null : () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            TextButton(
              key: const ValueKey('tmux.install.plain'),
              onPressed: installing ? null : shell.connectWithoutPersistence,
              child: const Text('Connect non-resumable'),
            ),
            TextButton(
              key: const ValueKey('tmux.install.confirm'),
              onPressed: installing ? null : shell.installTmuxAndConnect,
              child: Text(
                installing ? 'Installing…' : 'Install tmux',
                style: TextStyle(color: installing ? null : OmniColors.cyan),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _offlineDialog(BuildContext context, Server server) {
    final display = HostDisplay.instance;
    return AlertDialog(
      key: const ValueKey('offline.connect.dialog'),
      // Scrollable because the content is a multi-child Column with no scroll of its own: on a
      // small phone in landscape at 200% text it does not fit, and an AlertDialog clips rather
      // than scrolls unless it is asked to. Same shape as parity defects 112 and 113.
      scrollable: true,
      title: const Text('Host appears offline'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${display.name(server)} (${display.host(server)}:${server.port}) '
            "didn't complete OmniTerm's last automatic SSH check.",
            style: const TextStyle(fontSize: 13),
          ),
          const SizedBox(height: 8),
          Text(
            'The status may be out of date or the configured route may behave differently. '
            'Connect anyway to make a real SSH attempt.',
            style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant),
          ),
        ],
      ),
      actions: [
        TextButton(
          key: const ValueKey('offline.connect.cancel'),
          onPressed: shell.dismissOfflineConnectPrompt,
          child: const Text('Cancel'),
        ),
        TextButton(
          key: const ValueKey('offline.connect.confirm'),
          onPressed: shell.connectConfirmedOffline,
          child: const Text('Connect anyway'),
        ),
      ],
    );
  }
}
