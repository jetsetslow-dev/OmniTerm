import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../navigation.dart';
import '../theme/colors.dart';
import '../view_model/settings_view_model.dart';
import '../view_model/shell_view_model.dart';

enum _PendingGuard { settings, shell }

/// Installs the two app-wide navigation transactions from the Kotlin app.
class NavigationGuardHost extends StatefulWidget {
  const NavigationGuardHost({super.key, required this.child});

  final Widget child;

  @override
  State<NavigationGuardHost> createState() => _NavigationGuardHostState();
}

class _NavigationGuardHostState extends State<NavigationGuardHost> {
  NavigationController? _nav;
  _PendingGuard? _pending;
  Screen? _target;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final nav = context.read<NavigationController>();
    if (identical(nav, _nav)) return;
    _nav?.guards.remove(_guard);
    _nav = nav;
    nav.guards.add(_guard);
  }

  bool _guard(Screen from, Screen? requested) {
    if (_pending != null) return true;
    final target = requested ?? _backTarget();
    if (target == null || target == from) return false;

    if (from == Screen.settings && context.read<SettingsViewModel>().isDirty) {
      setState(() {
        _pending = _PendingGuard.settings;
        _target = target;
      });
      return true;
    }

    final shell = context.read<ShellViewModel>();
    if (from == Screen.shell && (shell.sessions.isNotEmpty || shell.isConnecting)) {
      setState(() {
        _pending = _PendingGuard.shell;
        _target = target;
      });
      return true;
    }
    return false;
  }

  Screen? _backTarget() {
    final history = _nav!.screenHistory;
    return history.length > 1 ? history[history.length - 2] : null;
  }

  void _stay() => setState(() {
    _pending = null;
    _target = null;
  });

  void _commit() {
    final target = _target;
    _stay();
    if (target != null) _nav!.commitNavigation(target);
  }

  @override
  void dispose() {
    _nav?.guards.remove(_guard);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Stack(
    children: [
      widget.child,
      if (_pending == _PendingGuard.settings) _settingsDialog(),
      if (_pending == _PendingGuard.shell) _shellDialog(),
    ],
  );

  Widget _settingsDialog() => Positioned.fill(
    child: Material(
      color: Colors.black54,
      child: Center(
        child: AlertDialog(
          key: const ValueKey('navigation.settingsDiscard'),
          title: const Text('Discard changes?'),
          content: const Text('You have unsaved Settings changes. Leave and discard them?'),
          actions: [
            TextButton(
              key: const ValueKey('navigation.settings.keepEditing'),
              onPressed: _stay,
              child: const Text('Keep editing'),
            ),
            TextButton(
              key: const ValueKey('navigation.settings.discard'),
              onPressed: () {
                context.read<SettingsViewModel>().revert();
                _commit();
              },
              child: const Text('Discard', style: TextStyle(color: OmniColors.red)),
            ),
          ],
        ),
      ),
    ),
  );

  Widget _shellDialog() {
    final vm = context.watch<ShellViewModel>();
    final sessions = vm.sessions;
    final allPersistent =
        sessions.isNotEmpty && sessions.every((session) => session.tmuxName != null);
    return Positioned.fill(
      child: Material(
        color: Colors.black54,
        child: Center(
          child: AlertDialog(
            key: const ValueKey('navigation.shellLeave'),
            title: Text(
              sessions.length > 1
                  ? '${sessions.length} active SSH sessions'
                  : allPersistent
                  ? 'Persistent SSH session'
                  : vm.isConnecting && sessions.isEmpty
                  ? 'SSH connection in progress'
                  : 'Active SSH session',
            ),
            content: Text(
              allPersistent
                  ? 'Leave the tmux session resumable, or terminate it and stop anything running there?'
                  : 'Choose what to do with the active terminal session. Keeping it in the background may increase battery use.',
            ),
            actions: [
              TextButton(
                key: const ValueKey('navigation.shell.disconnect'),
                onPressed: () async {
                  await vm.disconnectAll(terminatePersistent: true);
                  if (mounted) _commit();
                },
                child: Text(
                  vm.isConnecting && sessions.isEmpty ? 'Cancel connection' : 'Disconnect all',
                  style: const TextStyle(color: OmniColors.red),
                ),
              ),
              TextButton(
                key: const ValueKey('navigation.shell.background'),
                onPressed: () {
                  vm.leaveOrBackgroundAll();
                  _commit();
                },
                child: Text(allPersistent ? 'Leave resumable' : 'Send to background'),
              ),
              TextButton(
                key: const ValueKey('navigation.shell.stay'),
                onPressed: _stay,
                child: const Text('Stay'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
