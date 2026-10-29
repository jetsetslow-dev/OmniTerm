import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../data/app_database.dart';
import '../../domain/host_display.dart';
import '../../l10n/app_localizations.dart';
import '../navigation.dart';
import '../shell_state.dart';
import '../view_model/app_state.dart';
import '../view_model/servers_view_model.dart';
import 'omni_confirm.dart';

/// Kotlin's `HostLimitReconciliationDialog`: when the free Play Store build holds more hosts than it
/// allows, the user picks the one to keep and the rest are deleted. It cannot be dismissed, since
/// every other route into this state is already blocked and only a choice resolves it.
class HostLimitReconciliationDialog extends StatefulWidget {
  const HostLimitReconciliationDialog({super.key, required this.reason});

  final String reason;

  @override
  State<HostLimitReconciliationDialog> createState() => _HostLimitReconciliationDialogState();
}

class _HostLimitReconciliationDialogState extends State<HostLimitReconciliationDialog> {
  int? _selectedId;
  bool _busy = false;
  bool _endTmuxSessions = false;

  /// The tmux sessions on every host but the one picked, which keeping it would leave running.
  int _tmuxCount(List<Server> servers) => context.read<ServersViewModel>().tmuxSessionCount({
    for (final server in servers)
      if (server.id != _selectedId) server.id,
  });

  @override
  Widget build(BuildContext context) {
    final servers = context.watch<AppState>().servers;
    _selectedId ??= servers.firstOrNull?.id;
    final tmuxCount = _tmuxCount(servers);
    return Material(
      color: Colors.black54,
      child: Center(
        child: AlertDialog(
          key: const ValueKey('license.hostReconciliation'),
          title: const Text('Choose host to keep'),
          content: SizedBox(
            width: 440,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    widget.reason.isEmpty
                        ? 'The free Play Store build supports one saved host.'
                        : widget.reason,
                  ),
                  const SizedBox(height: 10),
                  RadioGroup<int>(
                    groupValue: _selectedId,
                    onChanged: _busy ? (_) {} : (value) => setState(() => _selectedId = value),
                    child: Column(
                      children: [
                        for (final server in servers)
                          RadioListTile<int>(
                            key: ValueKey('license.hostReconciliation.${server.id}'),
                            value: server.id,
                            enabled: !_busy,
                            title: Text(server.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                            subtitle: Text(
                              '${HostDisplay.instance.userAtHost(server)}:${server.port}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                      ],
                    ),
                  ),
                  // Offered only when keeping one host would leave tmux sessions running on the
                  // others; the remote machines are otherwise untouched.
                  if (tmuxCount > 0)
                    OmniOptionRow(
                      key: const ValueKey('license.hostReconciliation.endTmux'),
                      label: tmuxCount == 1
                          ? AppLocalizations.of(context).alsoEndTheTmuxSessionOnTheRemovedHosts
                          : AppLocalizations.of(
                              context,
                            ).alsoEndTheTmuxSessionsOnTheRemovedHosts(tmuxCount),
                      value: _endTmuxSessions,
                      onChanged: _busy ? null : (value) => setState(() => _endTmuxSessions = value),
                    ),
                ],
              ),
            ),
          ),
          actions: [
            FilledButton(
              key: const ValueKey('license.hostReconciliation.keep'),
              onPressed: _busy || _selectedId == null ? null : _keepSelected,
              child: Text(_busy ? 'Applying…' : 'Keep selected'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _keepSelected() async {
    final keepId = _selectedId;
    if (keepId == null) return;
    final endTmuxSessions = _endTmuxSessions && _tmuxCount(context.read<AppState>().servers) > 0;
    setState(() => _busy = true);
    await context.read<ServersViewModel>().reconcileHostLimit({
      keepId,
    }, endTmuxSessions: endTmuxSessions);
    if (!mounted) return;
    context.read<NavigationController>().navigateTo(Screen.servers);
    context.read<ShellState>().completeHostLimitReconciliation();
  }
}
