import 'dart:async';

import 'package:flutter/material.dart';

import '../../../data/app_database.dart';
import '../../../data/host_tools.dart';
import '../../../data/term/tmux_bootstrap.dart';
import '../../../domain/session_age.dart';
import '../../../l10n/app_localizations.dart';
import '../../navigation.dart';
import '../../theme/colors.dart';
import '../../theme/typography.dart';
import '../../view_model/shell_view_model.dart';
import '../../widgets/host_tool_notice.dart';
import '../../widgets/omni_components.dart';

/// Hosts ⋮ › Attach existing tmux…: the tmux sessions running on [server], to attach one here, as
/// Kotlin's `AttachTmuxDialog`. Closing it by any route stops the listing.
Future<void> showAttachTmuxDialog(
  BuildContext context,
  ShellViewModel shell,
  Server server, {
  NavigationController? navigation,
}) async {
  shell.openAttachTmux(server);
  await showDialog<void>(
    context: context,
    builder: (_) => _AttachTmuxDialog(shell: shell, navigation: navigation),
  );
  if (shell.tmuxAttachServer?.id == server.id) shell.dismissAttachTmux();
}

class _AttachTmuxDialog extends StatelessWidget {
  const _AttachTmuxDialog({required this.shell, this.navigation});

  final ShellViewModel shell;
  final NavigationController? navigation;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: shell,
    builder: (context, _) {
      final server = shell.tmuxAttachServer;
      if (server == null) return const SizedBox.shrink();
      final l10n = AppLocalizations.of(context);
      final listing = shell.tmuxAttachListing;
      final sessions = listing.sessions;
      const dense = TextStyle(fontSize: OmniTextSize.dense);
      final error = listing.error;
      return Dialog(
        key: const ValueKey('tmux.attach.dialog'),
        insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  l10n.tmuxSessionsOn(server.name),
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 8),
                if (listing.loading)
                  Row(
                    children: [
                      const SizedBox.square(
                        dimension: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                      const SizedBox(width: 8),
                      Text(l10n.listingTmuxSessions, style: dense),
                    ],
                  )
                else if (error != null)
                  Text(
                    error,
                    key: const ValueKey('tmux.attach.error'),
                    style: dense.copyWith(color: OmniColors.red),
                  )
                else if (sessions == null)
                  HostToolNotice(
                    server: server,
                    tool: HostTool.tmux,
                    text: l10n.tmuxIsNotInstalledOn(server.name),
                    fontSize: OmniTextSize.dense,
                    onInstalled: () => unawaited(shell.refreshAttachTmux()),
                  )
                else if (sessions.isEmpty)
                  Text(
                    l10n.noTmuxSessionsAreRunningOn(server.name),
                    key: const ValueKey('tmux.attach.none'),
                    style: dense,
                  )
                else ...[
                  Text(
                    l10n.attachingJoinsTheSessionItself,
                    style: const TextStyle(fontSize: OmniTextSize.meta),
                  ),
                  const SizedBox(height: 8),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 420),
                    child: ListView.separated(
                      shrinkWrap: true,
                      itemCount: sessions.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 6),
                      itemBuilder: (context, i) => _TmuxSessionRow(
                        shell: shell,
                        server: server,
                        session: sessions[i],
                        navigation: navigation,
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerRight,
                  child: Wrap(
                    children: [
                      TextButton(
                        key: const ValueKey('tmux.attach.refresh'),
                        onPressed: listing.loading ? null : shell.refreshAttachTmux,
                        child: Text(l10n.retry),
                      ),
                      TextButton(
                        key: const ValueKey('tmux.attach.close'),
                        onPressed: () => Navigator.of(context).pop(),
                        child: Text(l10n.close),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    },
  );
}

class _TmuxSessionRow extends StatelessWidget {
  const _TmuxSessionRow({
    required this.shell,
    required this.server,
    required this.session,
    this.navigation,
  });

  final ShellViewModel shell;
  final Server server;
  final RemoteTmuxSession session;
  final NavigationController? navigation;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final attachable = isAttachableTmuxName(session.name);
    final windows = session.windows == 1 ? l10n.tmuxOneWindow : l10n.tmuxWindows(session.windows);
    final state = shell.isTmuxSessionOpen(server.id, session.name)
        ? l10n.tmuxOpenHere
        : session.attachedClients > 0
        ? l10n.tmuxAttachedElsewhere
        : l10n.tmuxDetached;
    final started = l10n.startedAgo(
      formatSessionAge(DateTime.fromMillisecondsSinceEpoch(session.createdAtMs)),
    );
    const meta = TextStyle(fontSize: OmniTextSize.meta, fontFamily: OmniFonts.mono);
    return OmniCard(
      key: ValueKey('tmux.attach.session.${session.name}'),
      leftAccent: attachable ? OmniColors.cyan : null,
      inset: const EdgeInsets.all(10),
      onTap: attachable
          ? () {
              unawaited(shell.attachHostTmuxSession(session));
              Navigator.of(context).pop();
              navigation?.navigateTo(Screen.shell);
            }
          : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            session.name,
            style: const TextStyle(
              fontWeight: FontWeight.bold,
              fontFamily: OmniFonts.mono,
              fontSize: OmniTextSize.body,
            ),
          ),
          Text([windows, state, started].join(' · '), style: meta),
          if (!attachable)
            Text(
              l10n.renameThisTmuxSessionToAttach,
              style: const TextStyle(fontSize: OmniTextSize.meta, color: OmniColors.amber),
            ),
        ],
      ),
    );
  }
}
