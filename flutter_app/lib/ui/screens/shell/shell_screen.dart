import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../../data/app_database.dart';
import '../../../domain/host_display.dart';
import '../../../domain/terminal_key_encoder.dart';
import '../../../domain/terminal_links.dart';
import '../../../domain/terminal_soft_input.dart';
import '../../../platform/link_opener.dart';
import '../../../platform/license_controller.dart';
import '../../theme/colors.dart';
import '../../theme/terminal_theme.dart';
import '../../theme/typography.dart';
import '../../view_model/shell_session.dart';
import '../../../domain/session_age.dart';
import '../../view_model/shell_view_model.dart';
import '../servers/server_form_state.dart';
import '../../widgets/terminal_key_bar.dart';
import '../../widgets/terminal_surface.dart';
import '../../widgets/terminal_options_dialog.dart';
import '../../widgets/host_selector_bar.dart';
import '../../widgets/popup_scroll_behavior.dart';
import '../../widgets/omni_components.dart';

/// The Shell screen, ported from `ShellScreen` in `ui/ShellScreen.kt`.
///
/// Three states: nothing to connect to, a host waiting for a connection, and a live terminal. The
/// screen never shows an empty black rectangle that looks like a working shell — every state says
/// what it is.
class ShellScreen extends StatefulWidget {
  const ShellScreen({super.key, this.licenseController, this.compactIme = false});

  /// Computed above Scaffold, which removes the IME inset from its resized body.
  final bool compactIme;

  final LicenseController? licenseController;

  @override
  State<ShellScreen> createState() => _ShellScreenState();
}

class _ShellScreenState extends State<ShellScreen> {
  // Android can briefly report a tiny viewport during rotation. Moving the content into
  // the overflow wrapper must preserve the same terminal input and viewport.
  final _contentsKey = GlobalKey();

  @override
  Widget build(BuildContext context) {
    final compactIme = widget.compactIme;
    final licenseController = widget.licenseController;
    final vm = context.watch<ShellViewModel>();
    final session = vm.current;
    final palette = terminalPaletteFor(context, vm.preferences.terminalTheme);

    return Container(
      color: palette.background,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final contents = Column(
            key: _contentsKey,
            children: [
              if (!compactIme && vm.server != null)
                _TerminalHeader(vm: vm, licenseController: licenseController),
              if (vm.isLeavingSessions || vm.isBackgroundingSession) ...[
                const LinearProgressIndicator(),
                Text(
                  vm.isLeavingSessions
                      ? 'Saving resumable sessions…'
                      : 'Sending session to background…',
                ),
              ],
              if (session != null && vm.error != null)
                Padding(
                  padding: const EdgeInsets.all(8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      InkWell(
                        onTap: () => showDialog<void>(
                          context: context,
                          builder: (context) => AlertDialog(
                            title: const Text('Connection error'),
                            content: SingleChildScrollView(
                              child: Text(vm.error ?? 'The error was cleared.'),
                            ),
                            actions: [
                              TextButton(
                                onPressed: () => Navigator.pop(context),
                                child: const Text('Close'),
                              ),
                            ],
                          ),
                        ),
                        child: Text(
                          vm.error!,
                          key: const ValueKey('shell.active.error'),
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(color: OmniColors.red),
                        ),
                      ),
                      Wrap(
                        children: [
                          if (vm.canRetryConnection)
                            TextButton(
                              key: const ValueKey('shell.active.retry'),
                              onPressed: vm.isConnecting ? null : vm.retryConnection,
                              child: const Text('Retry'),
                            ),
                          TextButton(onPressed: vm.clearError, child: const Text('Dismiss')),
                        ],
                      ),
                    ],
                  ),
                ),
              // Shown wherever the Shell is, with or without an active session: the sessions this
              // warns about are precisely the ones the user is about to walk away from.
              if (vm.backgroundServiceWarning != null)
                Padding(
                  padding: const EdgeInsets.all(8),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          vm.backgroundServiceWarning!,
                          key: const ValueKey('shell.backgroundService.warning'),
                          style: const TextStyle(color: OmniColors.amber),
                        ),
                      ),
                      IconButton(
                        key: const ValueKey('shell.backgroundService.dismiss'),
                        icon: const Icon(Icons.close),
                        tooltip: 'Dismiss',
                        onPressed: vm.dismissBackgroundServiceWarning,
                      ),
                    ],
                  ),
                ),
              Expanded(
                child: vm.isConnecting
                    ? _ConnectingView(phase: vm.connectPhase)
                    : session == null
                    ? _ConnectPane(vm: vm, licenseController: licenseController)
                    : vm.isSplit
                    ? _SplitTerminals(
                        vm: vm,
                        first: vm.splitFirstSession!,
                        second: vm.splitSecondSession!,
                      )
                    : _ActiveTerminal(vm: vm, session: session),
              ),
              if (session != null) TerminalKeyBar(viewModel: vm, compact: compactIme),
            ],
          );
          // Android can briefly deliver the new orientation with the old IME height. Preserve
          // usable controls in that tiny viewport until the keyboard finishes resizing.
          final scaler = MediaQuery.textScalerOf(context);
          final headerHeight = compactIme || vm.server == null
              ? 0.0
              : scaler.scale(24) + 28 + (scaler.scale(24) + 12).clamp(34, double.infinity) + 4;
          final bodyMinimum = session == null
              ? 80.0 + (vm.resumableSessions.isEmpty ? 0 : 200)
              : (compactIme || session.readOnly ? 42.0 : 80.0) +
                    (vm.isSplit && vm.splitStacked
                        ? 80.0
                        : compactIme
                        ? 0.0
                        : 40.0);
          final minimumHeight =
              headerHeight + bodyMinimum + (vm.error == null ? 0 : 96 + scaler.scale(60));
          return constraints.maxHeight < minimumHeight
              ? SingleChildScrollView(
                  child: SizedBox(height: minimumHeight, child: contents),
                )
              : contents;
        },
      ),
    );
  }
}

// ── connect / empty states ────────────────────────────────────────────────────

/// Connects to a host that is not in the list, and is not added to it.
///
/// The row this builds is never handed to the repository — no host, no credential, no host-key
/// preference outlives the session. That is the whole feature: a one-off connection to a machine
/// you do not want in your fleet, which is a normal thing to want and a bad thing to have to
/// clean up afterwards.
///
/// The host key still goes through the usual trust prompt. A connection being temporary is not a
/// reason to skip the one check that tells you whether the machine is the one you meant.
Future<void> _quickConnect(
  BuildContext context,
  ShellViewModel vm, {
  LicenseController? licenseController,
}) async {
  if (licenseController != null &&
      licenseController.state.value.enabled &&
      !licenseController.state.value.unlocked) {
    await showModalBottomSheet<void>(
      context: context,
      // Scroll-controlled because a sheet is otherwise capped at half the available height: on a
      // small phone in landscape at 200% text that is ~180px, and this content needs far more.
      // The clipped part is the bottom, which is where the buttons are. Parity defects 112-115
      // are the same failure in dialogs.
      isScrollControlled: true,
      builder: (ctx) => Container(
        key: const ValueKey('shell.quickConnectEntitlementSheet'),
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Icon(Icons.lock, size: 48, color: OmniColors.amber),
            const SizedBox(height: 16),
            Text(
              'Quick Connect Requires Premium',
              style: Theme.of(ctx).textTheme.titleMedium?.copyWith(color: OmniColors.textPrimary),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              'Upgrade to OmniTerm Premium to use Quick Connect for one-off sessions.',
              style: Theme.of(ctx).textTheme.bodyMedium?.copyWith(color: OmniColors.textSecondary),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            ElevatedButton(
              key: const ValueKey('shell.quickConnectUpgradeButton'),
              onPressed: () {
                Navigator.pop(ctx);
                licenseController.launchPurchase();
              },
              child: Text(licenseController.state.value.productPrice ?? 'Upgrade to Premium'),
            ),
          ],
        ),
      ),
    );
    return;
  }

  final server = await showModalBottomSheet<Server>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => const _QuickConnectSheet(),
  );
  if (server != null) await vm.connect(server);
}

class _QuickConnectSheet extends StatefulWidget {
  const _QuickConnectSheet();

  @override
  State<_QuickConnectSheet> createState() => _QuickConnectSheetState();
}

class _QuickConnectSheetState extends State<_QuickConnectSheet> {
  final _host = TextEditingController();
  final _port = TextEditingController(text: '22');
  final _user = TextEditingController();
  final _password = TextEditingController();

  @override
  void dispose() {
    _host.dispose();
    _port.dispose();
    _user.dispose();
    _password.dispose();
    super.dispose();
  }

  bool get _valid =>
      _host.text.trim().isNotEmpty &&
      _user.text.trim().isNotEmpty &&
      (int.tryParse(_port.text.trim()) ?? 0) > 0;

  /// The in-memory row, built by the same code the host form uses so a quick connection and a saved
  /// one cannot drift apart in how they resolve credentials.
  Server _build() {
    final form = ServerFormState(mode: ServerFormMode.add)
      ..name = _host.text.trim()
      ..host = _host.text.trim()
      ..port = _port.text.trim()
      ..username = _user.text.trim()
      ..authType = 'password'
      ..password = _password.text;
    return form.toServer();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                const Expanded(
                  child: Text(
                    'Quick connect',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                  ),
                ),
                IconButton(
                  tooltip: 'Close',
                  key: const ValueKey('shell.quick.close'),
                  icon: const Icon(Icons.close, size: 18),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
            Text(
              'Nothing here is saved: the host, the username and the password live only for this '
              'session. The host key is still checked as usual.',
              key: const ValueKey('shell.quick.note'),
              style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  flex: 3,
                  child: TextField(
                    key: const ValueKey('shell.quick.host'),
                    controller: _host,
                    autofocus: true,
                    decoration: omniInputDecoration(context, labelText: 'Host'),
                    onChanged: (_) => setState(() {}),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    key: const ValueKey('shell.quick.port'),
                    controller: _port,
                    keyboardType: TextInputType.number,
                    decoration: omniInputDecoration(context, labelText: 'Port'),
                    onChanged: (_) => setState(() {}),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            TextField(
              key: const ValueKey('shell.quick.username'),
              controller: _user,
              decoration: omniInputDecoration(context, labelText: 'Username'),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 10),
            TextField(
              key: const ValueKey('shell.quick.password'),
              controller: _password,
              obscureText: true,
              decoration: omniInputDecoration(
                context,
                labelText: 'Password',
                helperText: 'Leave empty to try the agent or a key-less host',
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 16),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton(
                key: const ValueKey('shell.quick.connect'),
                onPressed: _valid ? () => Navigator.of(context).pop(_build()) : null,
                child: const Text('Connect'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ConnectPane extends StatelessWidget {
  const _ConnectPane({required this.vm, this.licenseController});

  final ShellViewModel vm;
  final LicenseController? licenseController;

  @override
  Widget build(BuildContext context) {
    if (vm.isConnecting) return _ConnectingView(phase: vm.connectPhase);

    final server = vm.server;
    if (server == null) {
      return _EmptyState(
        key: const ValueKey('shell.empty'),
        message: !vm.hasAnyHost
            // The two are different problems with different fixes, so they get different sentences.
            // "No hosts" is solved by adding one; "none online" is solved from the Hosts tab, which
            // is also the only place that warns before forcing SSH to a host believed to be down.
            ? 'Add a host first.'
            : 'No online hosts. To SSH into an offline host anyway, use its connect button on the '
                  'Hosts tab.',
        error: vm.error,
      );
    }

    return Column(
      children: [
        Expanded(
          child: _ConnectPrompt(vm: vm, server: server, licenseController: licenseController),
        ),
        // Below the connect prompt rather than instead of it: a session left running on a server is
        // something to *come back to*, so it belongs where the user arrives looking for a terminal.
        if (vm.resumableSessions.isNotEmpty) _ResumableSessions(vm: vm),
      ],
    );
  }
}

/// tmux sessions still running on a server with nothing attached to them.
class _ResumableSessions extends StatelessWidget {
  const _ResumableSessions({required this.vm});

  final ShellViewModel vm;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Container(
      key: const ValueKey('shell.resumable'),
      constraints: const BoxConstraints(maxHeight: 200),
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
      child: ScrollConfiguration(
        behavior: const PopupScrollBehavior(popupsOnly: false),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'Left running',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
              ),
              Text(
                // Saying where they are, because "resumable" alone reads as a local draft rather than
                // work still executing on someone else's machine.
                'These are still running on their servers. Resuming attaches to one again.',
                style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
              ),
              const SizedBox(height: 6),
              for (final row in vm.resumableSessions) _ResumableCard(vm: vm, row: row),
            ],
          ),
        ),
      ),
    );
  }
}

class _ResumableCard extends StatelessWidget {
  const _ResumableCard({required this.vm, required this.row});
  final ShellViewModel vm;
  final PersistentSession row;

  @override
  Widget build(BuildContext context) => OmniCard(
    key: ValueKey('shell.resumable.${row.tmuxName}'),
    leftAccent: OmniColors.amber,
    child: LayoutBuilder(
      builder: (context, constraints) {
        final scheme = Theme.of(context).colorScheme;
        final metadata = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(row.serverName, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
            Text(
              '${row.tmuxName}  ·  ${describeSessionAge(row)}',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 10,
                fontFamily: OmniFonts.mono,
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
        );
        final actions = [
          TextButton(
            key: ValueKey('shell.resumable.${row.tmuxName}.resume'),
            onPressed: vm.isConnecting ? null : () => vm.resume(row),
            child: const Text('Resume', style: TextStyle(fontSize: 12)),
          ),
          TextButton(
            key: ValueKey('shell.resumable.${row.tmuxName}.forget'),
            onPressed: () => _confirmForget(context, vm, row),
            child: Text('Forget', style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
          ),
        ];
        // Keep both actions reachable when system text scaling leaves no room beside the metadata.
        return constraints.maxWidth < 280 || MediaQuery.textScalerOf(context).scale(12) > 16
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  metadata,
                  Wrap(children: actions),
                ],
              )
            : Row(
                children: [
                  Expanded(child: metadata),
                  ...actions,
                ],
              );
      },
    ),
  );
}

Future<void> _confirmForget(BuildContext context, ShellViewModel vm, PersistentSession row) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      key: const ValueKey('shell.resumable.forget.dialog'),
      title: Text('Forget "${row.serverName}"?'),
      content: const Text(
        // The distinction that matters: this is a pointer on this device, not the session itself.
        'This only removes it from this list. The tmux session keeps running on the server — to '
        'end it, resume it and exit the shell.',
      ),
      actions: [
        TextButton(
          key: const ValueKey('shell.resumable.forget.cancel'),
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: const Text('Cancel'),
        ),
        TextButton(
          key: const ValueKey('shell.resumable.forget.confirm'),
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: const Text('Forget', style: TextStyle(color: OmniColors.red)),
        ),
      ],
    ),
  );
  if (confirmed ?? false) await vm.forgetResumable(row);
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({super.key, required this.message, this.error});

  final String message;
  final String? error;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            message,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontFamily: OmniFonts.mono,
              fontSize: 13,
              color: Color(0xFF7C8AA5),
            ),
          ),
          if (error != null) ...[
            const SizedBox(height: 16),
            Text(
              error!,
              key: const ValueKey('shell.error'),
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 12, color: OmniColors.red),
            ),
          ],
        ],
      ),
    ),
  );
}

class _ConnectPrompt extends StatelessWidget {
  const _ConnectPrompt({required this.vm, required this.server, this.licenseController});

  final ShellViewModel vm;
  final Server server;
  final LicenseController? licenseController;

  @override
  Widget build(BuildContext context) => Center(
    child: SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(
            '>_',
            style: TextStyle(
              color: OmniColors.cyan,
              fontSize: 34,
              fontFamily: OmniFonts.mono,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            server.name,
            style: const TextStyle(
              fontFamily: OmniFonts.mono,
              fontSize: 15,
              fontWeight: FontWeight.bold,
              color: Color(0xFFC8D4E8),
            ),
          ),
          // Routed through HostDisplay so "hide addresses" covers the terminal too. A screen the
          // user is most likely to be sharing is the last place to leak a host name.
          ListenableBuilder(
            listenable: HostDisplay.instance,
            builder: (context, _) => Text(
              '${HostDisplay.instance.userAtHost(server)}:${server.port}',
              key: const ValueKey('shell.connect.target'),
              style: const TextStyle(
                fontFamily: OmniFonts.mono,
                fontSize: 11,
                color: Color(0xFF7C8AA5),
              ),
            ),
          ),
          const SizedBox(height: 20),
          FilledButton.icon(
            key: const ValueKey('shell.connect'),
            icon: const Icon(Icons.play_arrow, size: 18),
            label: Text(vm.error == null ? 'Connect' : 'Retry'),
            onPressed: vm.canConnect
                ? () => vm.connect(server, controlMode: vm.useControlMode)
                : null,
          ),
          // Offered only where it means something: control mode is a property of a tmux attach, and
          // a host that never enters tmux has no protocol to speak.
          if (server.persistentSession)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Checkbox(
                    key: const ValueKey('shell.controlMode'),
                    value: vm.useControlMode,
                    onChanged: vm.canConnect ? (v) => vm.useControlMode = v ?? false : null,
                  ),
                  const Text('Attach in control mode', style: TextStyle(fontSize: 11)),
                  const SizedBox(width: 4),
                  Tooltip(
                    message:
                        'tmux sends every byte as an event instead of redrawing, so fast output '
                        'cannot be lost. This app draws one pane: splits made inside tmux will '
                        'not all be visible.',
                    child: const Icon(Icons.info_outline, size: 14, color: OmniColors.textMuted),
                  ),
                ],
              ),
            ),
          const SizedBox(height: 8),
          TextButton.icon(
            key: const ValueKey('shell.quickConnect'),
            icon: const Icon(Icons.bolt, size: 16),
            label: const Text('Quick connect', style: TextStyle(fontSize: 12)),
            onPressed: vm.canConnect
                ? () => _quickConnect(context, vm, licenseController: licenseController)
                : null,
          ),
          if (!vm.canConnect)
            const Padding(
              padding: EdgeInsets.only(top: 10),
              child: Text(
                // Convention 4: say the feature is off rather than opening a terminal that will
                // never receive a byte.
                'The terminal is unavailable in this build: no SSH transport is wired.',
                key: ValueKey('shell.unavailable'),
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 11, color: OmniColors.amber),
              ),
            ),
          if (vm.error != null) ...[
            const SizedBox(height: 16),
            Text(
              vm.error!,
              key: const ValueKey('shell.error'),
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 12, color: OmniColors.red),
            ),
          ],
        ],
      ),
    ),
  );
}

class _ConnectingView extends StatelessWidget {
  const _ConnectingView({this.phase});

  final String? phase;

  @override
  Widget build(BuildContext context) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(
          width: 28,
          height: 28,
          child: CircularProgressIndicator(strokeWidth: 2, color: OmniColors.cyan),
        ),
        const SizedBox(height: 14),
        Text(
          // The transport's own phase, not a generic spinner label: "Authenticating…" that sits
          // there for ten seconds tells the user which step is hanging.
          phase ?? 'Connecting…',
          key: const ValueKey('shell.phase'),
          style: const TextStyle(
            fontFamily: OmniFonts.mono,
            fontSize: 12,
            color: Color(0xFF7C8AA5),
          ),
        ),
      ],
    ),
  );
}

// ── session chips ─────────────────────────────────────────────────────────────

class _TerminalHeader extends StatefulWidget {
  const _TerminalHeader({required this.vm, this.licenseController});
  final ShellViewModel vm;
  final LicenseController? licenseController;

  @override
  State<_TerminalHeader> createState() => _TerminalHeaderState();
}

class _TerminalHeaderState extends State<_TerminalHeader> {
  String? _workPhase;
  ShellViewModel get vm => widget.vm;
  bool get busy =>
      vm.isConnecting || vm.isLeavingSessions || vm.isBackgroundingSession || _workPhase != null;

  Future<void> _switchHost(int? id) async {
    final host = vm.connectableServers.where((s) => s.id == id).firstOrNull;
    if (host == null || busy) return;
    final session = vm.current;
    if (session != null && session.serverId != host.id) {
      if (!await _confirmBackground(context, session)) return;
    }
    if (mounted) await vm.switchTerminalHost(host);
  }

  @override
  Widget build(BuildContext context) {
    final session = vm.current;
    final scheme = Theme.of(context).colorScheme;
    final persistent = session?.tmuxName != null;
    final readOnly = session?.readOnly ?? vm.terminalReadOnly;
    return Container(
      key: const ValueKey('shell.sessionBar'),
      color: scheme.surface.computeLuminance() > .5 ? scheme.surface : scheme.surfaceContainerHigh,
      child: Column(
        children: [
          HostSelectorBar(
            keyPrefix: 'shell.host',
            hosts: vm.connectableServers,
            selected: vm.server!,
            enabled: !busy,
            onChanged: _switchHost,
            leading: Text(
              vm.isSplit ? 'P${vm.focusedPane}' : 'TERM',
              style: const TextStyle(
                fontSize: 9,
                fontWeight: FontWeight.bold,
                fontFamily: OmniFonts.mono,
              ),
            ),
            trailing: Text(
              vm.isSplit ? 'FOCUSED' : 'CURRENT',
              style: const TextStyle(fontSize: 9, fontWeight: FontWeight.bold),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 4),
            child: Row(
              key: const ValueKey('shell.header.actions'),
              spacing: 6,
              children: [
                Expanded(
                  child: _TerminalOpenButton(
                    vm: vm,
                    enabled: !busy,
                    licenseController: widget.licenseController,
                  ),
                ),
                _action(
                  persistent ? 'LEAVE' : 'BG',
                  'shell.background',
                  persistent
                      ? 'Leave current tmux session resumable'
                      : 'Send current session to background',
                  scheme.onPrimaryContainer,
                  scheme.primaryContainer,
                  session != null && (persistent || session.isOpen) && !busy
                      ? () async {
                          if (await _confirmBackground(context, session)) {
                            await vm.backgroundSession(session);
                          }
                        }
                      : null,
                ),
                if (vm.isSplit) ...[
                  _action(
                    vm.splitStacked ? '⬌ COLS' : '⬍ STACK',
                    'shell.split.axis',
                    vm.splitStacked ? 'Show split panes side by side' : 'Stack split panes',
                    scheme.onSecondaryContainer,
                    scheme.secondaryContainer,
                    busy ? null : vm.toggleSplitAxis,
                  ),
                  _action(
                    'SINGLE',
                    'shell.split.single',
                    'Return to single terminal',
                    scheme.onTertiaryContainer,
                    scheme.tertiaryContainer,
                    busy ? null : vm.unsplit,
                  ),
                ] else
                  _action(
                    'SPLIT',
                    'shell.split',
                    'Open split terminal',
                    scheme.onSecondaryContainer,
                    scheme.secondaryContainer,
                    session != null && !busy ? () => _openSplitPicker(context, vm) : null,
                  ),
                _action(
                  readOnly ? '🔒 VIEW' : '🔓 INPUT',
                  'shell.readOnly',
                  readOnly ? 'Enable terminal input' : 'Enable read-only terminal mode',
                  readOnly ? scheme.onTertiaryContainer : scheme.onSecondaryContainer,
                  readOnly ? scheme.tertiaryContainer : scheme.secondaryContainer,
                  busy
                      ? null
                      : () {
                          vm.setTerminalReadOnly(!readOnly);
                          if (!readOnly) {
                            FocusManager.instance.primaryFocus?.unfocus();
                            SystemChannels.textInput.invokeMethod<void>('TextInput.hide');
                          }
                        },
                ),
                _action(
                  '⋮ OPT',
                  'shell.options',
                  'Open terminal options',
                  scheme.onSurfaceVariant,
                  scheme.surfaceContainerHighest,
                  session == null || busy ? null : () => openTerminalOptions(context, vm, session),
                ),
                if (session != null && !session.isOpen && !session.reconnecting)
                  _action(
                    'RECON',
                    'shell.header.reconnect',
                    'Reconnect current session',
                    scheme.onPrimaryContainer,
                    scheme.primaryContainer,
                    busy ? null : () => vm.retrySession(session),
                  ),
                _action(
                  'DISC',
                  'shell.disconnect',
                  'Disconnect current session',
                  scheme.onErrorContainer,
                  scheme.errorContainer,
                  session == null || busy
                      ? null
                      : () => _requestCloseSession(
                          context,
                          vm,
                          session,
                          onBegin: (phase) {
                            if (mounted) setState(() => _workPhase = phase);
                          },
                          onEnd: () {
                            if (mounted) setState(() => _workPhase = null);
                          },
                        ),
                ),
              ],
            ),
          ),
          if (_workPhase != null) ...[const LinearProgressIndicator(), Text(_workPhase!)],
        ],
      ),
    );
  }

  Widget _action(
    String label,
    String keyName,
    String hint,
    Color color,
    Color background,
    VoidCallback? onTap,
  ) => Expanded(
    child: _TerminalHeaderAction(
      label: label,
      keyName: keyName,
      hint: hint,
      color: color,
      background: background,
      onTap: onTap,
    ),
  );
}

class _TerminalHeaderAction extends StatelessWidget {
  const _TerminalHeaderAction({
    required this.label,
    required this.keyName,
    required this.hint,
    required this.color,
    required this.background,
    this.onTap,
  });
  final String label, keyName, hint;
  final Color color, background;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: hint,
    child: Semantics(
      label: hint,
      button: true,
      enabled: onTap != null,
      child: Material(
        color: background,
        borderRadius: BorderRadius.circular(6),
        child: InkWell(
          key: ValueKey(keyName),
          onTap: onTap,
          borderRadius: BorderRadius.circular(6),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 34),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 6),
              child: Center(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyLarge!.copyWith(
                    fontSize: 10,
                    height:
                        MediaQuery.textScalerOf(context).scale(24) /
                        MediaQuery.textScalerOf(context).scale(10),
                    letterSpacing: MediaQuery.textScalerOf(context).scale(.5),
                    fontWeight: FontWeight.bold,
                    color: onTap == null
                        ? Theme.of(context).colorScheme.onSurfaceVariant.withValues(alpha: .58)
                        : color,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

Future<bool> _confirmBackground(BuildContext context, ShellSession session) async {
  final persistent = session.tmuxName != null;
  return await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text(persistent ? 'Leave Session Resumable?' : 'Send Session to Background?'),
          content: Text(
            persistent
                ? 'OmniTerm will detach and close this local SSH connection. The tmux session and anything running inside it stay available to resume.'
                : 'OmniTerm will keep the SSH session active in the background. This may increase battery consumption.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Cancel'),
            ),
            TextButton(
              key: const ValueKey('shell.background.confirm'),
              onPressed: () => Navigator.pop(dialogContext, true),
              child: Text(persistent ? 'Leave resumable' : 'Send to background'),
            ),
          ],
        ),
      ) ??
      false;
}

class _TerminalOpenButton extends StatelessWidget {
  const _TerminalOpenButton({required this.vm, required this.enabled, this.licenseController});
  final ShellViewModel vm;
  final bool enabled;
  final LicenseController? licenseController;

  Future<void> _open(BuildContext context) async {
    final current = vm.current;
    final background = vm.sessions.where((s) => s != current && s != vm.splitSession).toList();
    final saved = vm.resumableSessions
        .where((row) => vm.sessions.every((s) => s.tmuxName != row.tmuxName))
        .toList();
    final anchor = context.findRenderObject()! as RenderBox;
    final overlay = Navigator.of(context).overlay!.context.findRenderObject()! as RenderBox;
    final origin = anchor.localToGlobal(Offset.zero, ancestor: overlay);
    final choice = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
        Rect.fromLTWH(origin.dx, origin.dy + anchor.size.height, anchor.size.width, 0),
        Offset.zero & overlay.size,
      ),
      constraints: const BoxConstraints(minWidth: 260, maxWidth: 340, maxHeight: 440),
      items: [
        if (current != null) ...[
          PopupMenuItem<String>(
            enabled: false,
            child: _TerminalSessionMenuLabel(
              title: '${vm.isSplit ? 'PANE ${vm.focusedPane}' : 'CURRENT'} · ${current.serverName}',
              detail: current.tmuxName,
              startedAt: current.startedAt.millisecondsSinceEpoch,
            ),
          ),
          const PopupMenuDivider(),
        ],
        if (background.isNotEmpty) ...[
          const PopupMenuItem<String>(
            enabled: false,
            child: Text(
              'Background sessions',
              style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold),
            ),
          ),
          for (final session in background)
            PopupMenuItem<String>(
              key: ValueKey('shell.session.${session.id}'),
              value: 'session:${session.id}',
              child: _TerminalSessionMenuLabel(
                title: session.serverName,
                detail: session.tmuxName ?? 'Live SSH session',
                startedAt: session.startedAt.millisecondsSinceEpoch,
                backgroundedAt: vm.backgroundedAtFor(session.id),
              ),
            ),
        ],
        if (saved.isNotEmpty) ...[
          if (background.isNotEmpty) const PopupMenuDivider(),
          const PopupMenuItem<String>(
            enabled: false,
            child: Text(
              'Resumable tmux',
              style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold),
            ),
          ),
          for (final row in saved)
            PopupMenuItem<String>(
              key: ValueKey('shell.open.saved.${row.tmuxName}'),
              value: 'saved:${row.tmuxName}',
              child: _TerminalSessionMenuLabel(
                title: row.serverName,
                detail: row.tmuxName,
                startedAt: row.createdAt,
                backgroundedAt: row.backgroundedAt,
              ),
            ),
        ],
        if (current != null || background.isNotEmpty || saved.isNotEmpty) const PopupMenuDivider(),
        PopupMenuItem<String>(
          key: const ValueKey('shell.newSession'),
          value: 'new',
          enabled: vm.canConnect && vm.server != null,
          child: Text(
            'New session · ${vm.server?.name ?? 'selected host'}',
            style: const TextStyle(fontFamily: OmniFonts.mono),
          ),
        ),
        if (licenseController == null ||
            !licenseController!.state.value.enabled ||
            licenseController!.state.value.unlocked)
          const PopupMenuItem<String>(
            value: 'quick',
            child: Text(
              "Quick connect (don't save)…",
              style: TextStyle(fontFamily: OmniFonts.mono),
            ),
          ),
      ],
    );
    if (!context.mounted || choice == null) return;
    if (choice.startsWith('session:')) {
      vm.resumeExisting(choice.substring(8));
    } else if (choice.startsWith('saved:')) {
      final row = saved.where((r) => r.tmuxName == choice.substring(6)).firstOrNull;
      if (row != null) await vm.resume(row);
    } else if (choice == 'new') {
      if (vm.server != null) await vm.connect(vm.server!);
    } else if (choice == 'quick') {
      await _quickConnect(context, vm, licenseController: licenseController);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Builder(
      builder: (anchorContext) => _TerminalHeaderAction(
        label: 'OPEN',
        keyName: 'shell.open',
        hint: 'Open or switch terminal session',
        color: scheme.onPrimaryContainer,
        background: scheme.primaryContainer,
        onTap: enabled ? () => _open(anchorContext) : null,
      ),
    );
  }
}

class _TerminalSessionMenuLabel extends StatefulWidget {
  const _TerminalSessionMenuLabel({
    required this.title,
    required this.startedAt,
    this.detail,
    this.backgroundedAt,
  });
  final String title;
  final String? detail;
  final int startedAt;
  final int? backgroundedAt;
  @override
  State<_TerminalSessionMenuLabel> createState() => _TerminalSessionMenuLabelState();
}

class _TerminalSessionMenuLabelState extends State<_TerminalSessionMenuLabel> {
  Timer? _clock;
  @override
  void initState() {
    super.initState();
    _clock = Timer.periodic(const Duration(minutes: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _clock?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(widget.title, style: const TextStyle(fontFamily: OmniFonts.mono, fontSize: 12)),
      if (widget.detail != null) Text(widget.detail!, style: const TextStyle(fontSize: 10)),
      Text(
        'Started ${formatSessionAge(DateTime.fromMillisecondsSinceEpoch(widget.startedAt))} ago${widget.backgroundedAt != null && widget.backgroundedAt! > 0 ? ' · backgrounded ${formatSessionAge(DateTime.fromMillisecondsSinceEpoch(widget.backgroundedAt!))} ago' : ''}',
        style: const TextStyle(fontSize: 10),
      ),
    ],
  );
}

Future<void> _requestCloseSession(
  BuildContext context,
  ShellViewModel vm,
  ShellSession session, {
  ValueChanged<String>? onBegin,
  VoidCallback? onEnd,
}) async {
  if (!session.isOpen) {
    vm.dismissEnded(session);
    return;
  }
  final persistent = session.tmuxName != null;
  final choice = await showDialog<String>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      key: ValueKey('shell.session.${session.id}.closeDialog'),
      title: Text(persistent ? 'Close persistent session?' : 'Disconnect session?'),
      content: Text(
        persistent
            ? 'Leave it resumable to close only this SSH connection, or terminate the remote tmux session and stop anything running inside it.'
            : 'Disconnect ${session.serverName} and stop anything running in this terminal?',
      ),
      actions: [
        TextButton(
          key: ValueKey('shell.session.${session.id}.cancelClose'),
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: const Text('Cancel'),
        ),
        if (persistent)
          TextButton(
            key: ValueKey('shell.session.${session.id}.leave'),
            onPressed: () => Navigator.of(dialogContext).pop('leave'),
            child: const Text('Leave resumable'),
          ),
        TextButton(
          key: ValueKey('shell.session.${session.id}.disconnect'),
          onPressed: () => Navigator.of(dialogContext).pop('disconnect'),
          child: Text(
            persistent ? 'Terminate' : 'Disconnect',
            style: const TextStyle(color: OmniColors.red),
          ),
        ),
      ],
    ),
  );
  if (choice == null) return;
  onBegin?.call(choice == 'leave' ? 'Saving session recovery…' : 'Disconnecting session…');
  try {
    if (choice == 'leave') {
      await vm.leaveResumable(session);
    } else if (choice == 'disconnect') {
      if (persistent) {
        await vm.terminate(session);
      } else {
        vm.close(session);
      }
    }
  } finally {
    onEnd?.call();
  }
}

// ── the live terminal ─────────────────────────────────────────────────────────

class _ActiveTerminal extends StatefulWidget {
  const _ActiveTerminal({required this.vm, required this.session});

  final ShellViewModel vm;
  final ShellSession session;

  @override
  State<_ActiveTerminal> createState() => _ActiveTerminalState();
}

class _ActiveTerminalState extends State<_ActiveTerminal> {
  /// Drives the platform's software keyboard.
  ///
  /// Invisible, and emptied after every commit: the terminal — not this field — is the record of
  /// what was typed, and leaving text in it would let a backspace edit history the remote has
  /// already consumed.
  final TextEditingController _input = TextEditingController();

  /// Owns the platform IME, so focusing it raises the software keyboard.
  final FocusNode _imeFocus = FocusNode(debugLabel: 'terminal-ime');

  /// Sits *above* the field and takes first refusal on hardware keys.
  ///
  /// Two nodes rather than one because a [FocusNode] can only be attached to a single widget, and
  /// the two jobs are genuinely different: the field must hold focus for the soft keyboard to have
  /// anywhere to deliver text, while Escape, the arrows and the function row have to be intercepted
  /// before the text field's own editing shortcuts turn them into cursor movement inside a field
  /// the user cannot even see.
  final FocusNode _keyFocus = FocusNode(debugLabel: 'terminal-keys');
  String _smartValue = '';
  final Object _smartInputOwner = Object();
  bool? _lastSmartSwipeInput;
  bool _isPasting = false;

  /// The last (session, pane focus, read-only) triple acted on, standing in for the key list of
  /// Kotlin's `LaunchedEffect` — see the comparison in [build].
  ({String id, bool focused, bool readOnly})? _lastFocusState;

  @override
  void dispose() {
    widget.vm.unregisterSmartInput(_smartInputOwner);
    _input.dispose();
    _imeFocus.dispose();
    _keyFocus.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant _ActiveTerminal oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.vm, widget.vm) || !identical(oldWidget.session, widget.session)) {
      oldWidget.vm.unregisterSmartInput(_smartInputOwner);
      _resetSmartInput();
      _lastFocusState = null;
    }
  }

  void _resetSmartInput() {
    _smartValue = '';
    _input.clear();
  }

  void _onCommit(BuildContext context, String text) {
    if (!identical(widget.vm.current, widget.session) ||
        widget.session.readOnly ||
        !widget.session.isOpen) {
      _resetSmartInput();
      return;
    }
    if (widget.vm.hasModifier) {
      final inserted = insertedTerminalModifierText(_smartValue, text);
      if (inserted.isNotEmpty) widget.vm.typeText(inserted);
      _resetSmartInput();
      return;
    }
    if (widget.vm.smartSwipeInput) {
      final old = _smartValue;
      if (insertedTerminalRuneDelta(old, text) > softInputPasteThreshold) {
        _resetSmartInput();
        _confirmPaste(context, text);
        return;
      }
      final newline = text.indexOf(RegExp(r'[\r\n]'));
      if (newline >= 0) {
        final before = text.substring(0, newline);
        final edit = terminalLineEdit(old, before);
        widget.vm.applyLineEdit(backspaces: edit.backspaces, insert: edit.insert);
        widget.vm.sendKey(TermKey.enter);
        var remainderAt = newline + 1;
        if (text[newline] == '\r' && remainderAt < text.length && text[remainderAt] == '\n') {
          remainderAt++;
        }
        final remainder = text.substring(remainderAt);
        if (remainder.isNotEmpty) widget.vm.paste(remainder);
        _resetSmartInput();
        return;
      }
      final edit = terminalLineEdit(old, text);
      widget.vm.applyLineEdit(backspaces: edit.backspaces, insert: edit.insert);
      _smartValue = text;
      return;
    }

    _input.clear();
    final action = interpretSoftInput(text);
    switch (action) {
      case SoftInputType(text: final t):
        widget.vm.typeText(t);
      case SoftInputEnter():
        widget.vm.sendKey(TermKey.enter);
      case SoftInputPaste(text: final t):
        _confirmPaste(context, t);
      case null:
        break;
    }
  }

  Future<void> _confirmPaste(BuildContext context, String text) async {
    if (_isPasting) {
      ScaffoldMessenger.maybeOf(
        context,
      )?.showSnackBar(const SnackBar(content: Text('A terminal paste is already pending.')));
      return;
    }
    setState(() => _isPasting = true);
    String result;
    try {
      result = await pasteTerminalText(
        context,
        widget.vm,
        widget.session,
        text,
        connectionRevision: widget.session.connectionRevision,
        requireConfirmation: true,
      );
    } catch (error) {
      result = 'Could not paste into terminal: $error';
    }
    if (!mounted || !context.mounted) return;
    setState(() => _isPasting = false);
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(result)));
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent) return KeyEventResult.ignored;

    final keyboard = HardwareKeyboard.instance;
    final ctrl = keyboard.isControlPressed;
    final alt = keyboard.isAltPressed;
    final shift = keyboard.isShiftPressed;

    final key = _termKeyFor(event.logicalKey);
    if (key != null) {
      // The modifiers held on the keyboard belong to this keystroke. Kotlin assigns them before
      // every physical key (`ui/ShellScreen.kt:2322`); without it a hardware Ctrl+Left arrived as a
      // bare Left, because the encoder was only ever told about the on-screen sticky modifiers.
      widget.vm.applyHardwareModifiers(shift: shift, alt: alt, ctrl: ctrl);
      widget.vm.sendKey(key);
      if (widget.vm.smartSwipeInput) _resetSmartInput();
      return KeyEventResult.handled;
    }

    // Android reports AltGr as Ctrl+Alt, so that combination is left to the text-input path — an
    // international layout typing `@` or `\` must not be read as a control chord. Kotlin says the
    // same at `ui/ShellScreen.kt:2363`.
    final isAltGr = ctrl && alt;
    if ((ctrl || alt) && !isAltGr) {
      // `character` is null for a Ctrl chord on most platforms — the modifier suppresses the text —
      // so the letter comes from the logical key instead. Kotlin reads `utf16CodePoint`, which
      // Android fills in the same way for the same reason.
      final label = event.character ?? event.logicalKey.keyLabel;
      if (label.length == 1 && label.codeUnitAt(0) >= 0x20) {
        widget.vm.applyHardwareModifiers(shift: shift, alt: alt, ctrl: ctrl);
        widget.vm.typeText(label.toLowerCase());
        if (widget.vm.smartSwipeInput) _resetSmartInput();
        return KeyEventResult.handled;
      }
    }

    final character = event.character;
    if (character != null && character.isNotEmpty && character.codeUnitAt(0) >= 0x20) {
      widget.vm.typeText(character);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final session = widget.session;
    final preferences = widget.vm.preferences;
    // The VM is mutable and shared by oldWidget/newWidget. Keep the actual previously rendered
    // mode so an override clears composition once, without clearing it on unrelated host updates.
    if (_lastSmartSwipeInput != widget.vm.smartSwipeInput) {
      _lastSmartSwipeInput = widget.vm.smartSwipeInput;
      _resetSmartInput();
    }
    final palette = terminalPaletteFor(context, preferences.terminalTheme);

    return ListenableBuilder(
      listenable: session,
      builder: (context, _) {
        // Kotlin's `LaunchedEffect(sessionId, isFocused, terminalReadOnly)` at
        // `ShellScreen.kt:1889`: a focused, writable pane takes the hidden input — and therefore
        // raises the keyboard — while a read-only one gives it back.
        //
        // The three values are compared rather than acted on every build, because that is what
        // `LaunchedEffect` keys mean: run when one of these changes, not on every recomposition.
        // Re-requesting focus on every build would fight the user, re-raising a keyboard they had
        // just dismissed with Back.
        final focusState = (
          id: session.id,
          focused: widget.vm.current?.id == session.id,
          readOnly: session.readOnly,
        );
        if (_lastFocusState != focusState) {
          _resetSmartInput();
          _lastFocusState = focusState;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted || _lastFocusState != focusState) return;
            if (focusState.focused && !focusState.readOnly) {
              _imeFocus.requestFocus();
            } else {
              _imeFocus.unfocus();
            }
          });
        }
        if (focusState.focused && !focusState.readOnly && widget.vm.smartSwipeInput) {
          widget.vm.registerSmartInput(_smartInputOwner, session, _resetSmartInput);
        } else {
          widget.vm.unregisterSmartInput(_smartInputOwner);
        }
        return Column(
          children: [
            if (_isPasting) ...[
              const LinearProgressIndicator(key: ValueKey('shell.paste.progress')),
              const Text('Preparing terminal paste…', maxLines: 1, overflow: TextOverflow.ellipsis),
            ],
            if (!session.isOpen || session.controlRefreshing || session.paneChangePending)
              _TerminalStatusRow(vm: widget.vm, session: session),
            if (session.controlRefreshError != null)
              Padding(
                padding: const EdgeInsets.all(8),
                child: Text(
                  session.controlRefreshError!,
                  key: const ValueKey('shell.pane.error'),
                  style: const TextStyle(color: OmniColors.red),
                ),
              ),
            Expanded(
              child: Focus(
                focusNode: _keyFocus,
                // Ancestor of the field, so it sees a hardware key before the field's own editing
                // shortcuts do. Anything it does not claim falls through to ordinary text entry.
                onKeyEvent: _onKey,
                child: Stack(
                  children: [
                    TerminalSurface(
                      session: session,
                      fontSize: preferences.terminalFontSize.toDouble(),
                      palette: palette,
                      focused: _imeFocus.hasFocus,
                      onGridChanged: widget.vm.rememberGrid,
                      onLongPressFocus: () => widget.vm.focusPane(session.id),
                      onOpenOptions: () async {
                        if (!session.readOnly) _imeFocus.requestFocus();
                        await openTerminalOptions(context, widget.vm, session);
                        if (mounted &&
                            identical(widget.vm.current, session) &&
                            session.isOpen &&
                            !session.readOnly) {
                          _imeFocus.requestFocus();
                        }
                      },
                      queryTuiActive: () => widget.vm.isPaneTuiActiveFor(session),
                      sendTuiPages: (up, count) =>
                          widget.vm.sendPageKeysFor(session, up: up, count: count),
                      // Scrolling into history is what pays for the tmux capture (ledger 99): the
                      // rows the user is reaching for may never have reached this client.
                      onScrolledBack: () => unawaited(widget.vm.resyncTmuxScrollback(session)),
                      onTapCell: (snapshot, row, column) async {
                        widget.vm.focusPane(session.id);
                        final value = preferences.terminalLinkDetection
                            ? terminalLinkAtCell(snapshot, row, column)
                            : null;
                        if (value != null) {
                          final opened = await openLink(
                            Uri.parse(value),
                            inApp: preferences.linkOpenInApp,
                            // The colour role Kotlin passes at `ui/ShellScreen.kt:1846`, so a link
                            // opened from the terminal arrives in the app's own chrome rather than
                            // the browser's default grey.
                            toolbarColor: Theme.of(context).colorScheme.surface.toARGB32(),
                          );
                          if (!opened && context.mounted) {
                            ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                              const SnackBar(content: Text('No app could open that link.')),
                            );
                          }
                          return;
                        }
                        // A read-only tap focuses the pane for scrolling and stops there. Kotlin
                        // spells this out at `ShellScreen.kt:2077` — "Read-only taps may focus a
                        // split pane for scrolling but never summon its keyboard" — and it is not
                        // cosmetic: input is dropped in read-only mode
                        // (`shell_view_model.dart:899`), so the keyboard would cover the output the
                        // user is trying to read in order to accept keystrokes that go nowhere.
                        if (!session.readOnly) _imeFocus.requestFocus();
                      },
                    ),
                    // Sized to nothing and painted with nothing: it exists purely to own the platform
                    // IME connection so the software keyboard has somewhere to deliver text.
                    Positioned(
                      width: 1,
                      height: 1,
                      child: Opacity(
                        opacity: 0,
                        child: TextField(
                          key: const ValueKey('shell.input'),
                          controller: _input,
                          focusNode: _imeFocus,
                          onChanged: (text) => _onCommit(context, text),
                          // A terminal needs literal keystrokes. Sentence casing would capitalise the
                          // first letter of every command, and autocorrect would rewrite flag names.
                          autocorrect: false,
                          enableSuggestions: widget.vm.smartSwipeInput,
                          textCapitalization: TextCapitalization.none,
                          // Kotlin uses ImeAction.None: Enter inserts a newline into this hidden
                          // multiline field, which the input interpreter sends as terminal CR.
                          textInputAction: TextInputAction.newline,
                          keyboardType: widget.vm.smartSwipeInput
                              ? TextInputType.multiline
                              : TextInputType.visiblePassword,
                          maxLines: null,
                        ),
                      ),
                    ),
                    if (!session.followTail)
                      Positioned(
                        right: 12,
                        bottom: 12,
                        child: FloatingActionButton.small(
                          key: const ValueKey('shell.jumpToBottom'),
                          backgroundColor: OmniColors.cyan,
                          onPressed: session.scrollToTail,
                          child: const Icon(Icons.arrow_downward, size: 18, color: Colors.black),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  static TermKey? _termKeyFor(LogicalKeyboardKey key) => switch (key) {
    LogicalKeyboardKey.enter || LogicalKeyboardKey.numpadEnter => TermKey.enter,
    LogicalKeyboardKey.backspace => TermKey.backspace,
    LogicalKeyboardKey.tab => TermKey.tab,
    LogicalKeyboardKey.escape => TermKey.esc,
    LogicalKeyboardKey.arrowUp => TermKey.up,
    LogicalKeyboardKey.arrowDown => TermKey.down,
    LogicalKeyboardKey.arrowLeft => TermKey.left,
    LogicalKeyboardKey.arrowRight => TermKey.right,
    LogicalKeyboardKey.home => TermKey.home,
    LogicalKeyboardKey.end => TermKey.end,
    LogicalKeyboardKey.insert => TermKey.insert,
    LogicalKeyboardKey.delete => TermKey.delete,
    LogicalKeyboardKey.pageUp => TermKey.pageUp,
    LogicalKeyboardKey.pageDown => TermKey.pageDown,
    LogicalKeyboardKey.f1 => TermKey.f1,
    LogicalKeyboardKey.f2 => TermKey.f2,
    LogicalKeyboardKey.f3 => TermKey.f3,
    LogicalKeyboardKey.f4 => TermKey.f4,
    LogicalKeyboardKey.f5 => TermKey.f5,
    LogicalKeyboardKey.f6 => TermKey.f6,
    LogicalKeyboardKey.f7 => TermKey.f7,
    LogicalKeyboardKey.f8 => TermKey.f8,
    LogicalKeyboardKey.f9 => TermKey.f9,
    LogicalKeyboardKey.f10 => TermKey.f10,
    LogicalKeyboardKey.f11 => TermKey.f11,
    LogicalKeyboardKey.f12 => TermKey.f12,
    _ => null,
  };
}

/// The strip above the grid: what state this session is in, and the two toggles that change it.
class _TerminalStatusRow extends StatelessWidget {
  const _TerminalStatusRow({required this.vm, required this.session});

  final ShellViewModel vm;
  final ShellSession session;

  @override
  Widget build(BuildContext context) {
    final ended = !session.isOpen;

    return Container(
      height: 30,
      color: const Color(0xFF0B1017),
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        children: [
          if (session.controlRefreshing)
            const Padding(
              padding: EdgeInsets.only(right: 8),
              child: SizedBox(
                width: 12,
                height: 12,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          Expanded(
            child: Text(
              _status(),
              key: const ValueKey('shell.status'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontFamily: OmniFonts.mono,
                fontSize: 10,
                color: ended ? OmniColors.amber : const Color(0xFF7C8AA5),
              ),
            ),
          ),
          if (!ended && session.paneChangePending && !session.controlRefreshing)
            TextButton(
              key: const ValueKey('shell.refreshPane'),
              onPressed: () => vm.refreshControlActivePane(session),
              child: const Text('Retry pane', style: TextStyle(fontSize: 11)),
            ),
          if (ended)
            if (session.endReason == ShellSessionEnd.disconnected && !session.reconnecting)
              TextButton(
                key: const ValueKey('shell.retry'),
                onPressed: () => vm.retrySession(session),
                child: const Text('Retry', style: TextStyle(fontSize: 11)),
              ),
          if (ended)
            TextButton(
              key: const ValueKey('shell.dismiss'),
              onPressed: () => vm.dismissEnded(session),
              child: const Text('Dismiss', style: TextStyle(fontSize: 11)),
            ),
        ],
      ),
    );
  }

  String _status() => session.reconnecting
      ? 'Reconnecting… Scrollback kept.'
      : switch (session.endReason) {
          ShellSessionEnd.open =>
            session.controlRefreshError ??
                (session.paneChangePending
                    ? 'Loading tmux pane… Input held.'
                    : session.readOnly
                    ? 'READ ONLY · ${session.cols}×${session.rows} · drag to scroll'
                    : '${session.serverName} · ${session.cols}×${session.rows}'),
          // The exit status is the useful part of a clean exit, so it is shown rather than summarised.
          ShellSessionEnd.remoteExited =>
            'Session ended (exit ${session.exitStatus ?? 0}). Scrollback kept.',
          // Named as a connection problem, not as an exit: the remote may well still be running, and
          // telling the user their shell "ended" would be a lie they act on.
          ShellSessionEnd.disconnected =>
            session.reconnectError ?? 'Connection lost. Scrollback kept.',
          ShellSessionEnd.closedByUser => 'Closed.',
        };
}

/// Two terminals at once, the app's headline Shell feature.
///
/// Each pane is an ordinary [_ActiveTerminal]; nothing about a session changes because it is in a
/// split. That is why this could be added late — `ShellSession` has owned its own geometry, scroll
/// position and read-only flag since it was first ported, so the surface reports its real grid to
/// the remote per pane and neither terminal learns the other exists.
class _SplitTerminals extends StatelessWidget {
  const _SplitTerminals({required this.vm, required this.first, required this.second});

  final ShellViewModel vm;
  final ShellSession first;
  final ShellSession second;

  @override
  Widget build(BuildContext context) {
    final panes = [
      Expanded(
        child: _FocusablePane(paneIndex: 1, vm: vm, session: first, focused: first == vm.current),
      ),
      const _SplitDivider(),
      Expanded(
        child: _FocusablePane(paneIndex: 2, vm: vm, session: second, focused: second == vm.current),
      ),
    ];

    return Column(
      key: const ValueKey('shell.splitView'),
      children: [
        Expanded(
          child: vm.splitStacked ? Column(children: panes) : Row(children: panes),
        ),
      ],
    );
  }
}

class _SplitDivider extends StatelessWidget {
  const _SplitDivider();

  @override
  Widget build(BuildContext context) => Container(width: 1, height: 1, color: OmniColors.cyan);
}

/// A pane that takes focus when tapped, and shows which one has it.
///
/// Focus is not decoration here: every per-session action — keystrokes, the key bar, disconnect —
/// targets the focused pane, so a split with no visible focus would leave the user guessing which
/// terminal is about to receive what they type.
class _FocusablePane extends StatelessWidget {
  const _FocusablePane({
    required this.paneIndex,
    required this.vm,
    required this.session,
    required this.focused,
  });

  final int paneIndex;
  final ShellViewModel vm;
  final ShellSession session;
  final bool focused;

  @override
  Widget build(BuildContext context) {
    // No gesture detector here on purpose — the terminal surface below claims the arena, so a
    // wrapper's tap would never fire. Focus is taken in `_ActiveTerminal`, where the tap lands.
    return Semantics(
      key: ValueKey('shell.pane.${session.id}'),
      container: true,
      explicitChildNodes: true,
      label: 'Terminal pane $paneIndex: ${session.serverName}',
      value: focused ? 'Active terminal pane' : 'Inactive terminal pane',
      selected: focused,
      hint: 'Focus terminal pane $paneIndex',
      // This is an accessibility action, not a competing pointer handler. The terminal surface
      // keeps owning real taps while TalkBack can move the same focus that a tap would move.
      onTap: () => vm.focusPane(session.id),
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border.all(color: focused ? OmniColors.cyan : Colors.transparent),
        ),
        child: _ActiveTerminal(vm: vm, session: session),
      ),
    );
  }
}

/// Picks what goes in the second pane: an open session, or a host to connect into it.
Future<void> _openSplitPicker(BuildContext context, ShellViewModel vm) async {
  final candidates = vm.splitCandidates;
  // Hosts with no session open. Kotlin lets two hosts be loaded into panes in one action, so an
  // unconnected host belongs in this list; picking one connects it into the second pane.
  final openIds = vm.sessions.map((session) => session.serverId).toSet();
  final connectable = vm.connectableServers
      .where((server) => !openIds.contains(server.id))
      .toList();
  await showModalBottomSheet<void>(
    context: context,
    useSafeArea: true,
    // Scroll-controlled because a sheet is otherwise capped at half the available height: on a
    // small phone in landscape at 200% text that is ~180px, and this content needs far more.
    // The clipped part is the bottom, which is where the buttons are. Parity defects 112-115
    // are the same failure in dialogs.
    isScrollControlled: true,
    builder: (sheetContext) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text('Show alongside', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
          if (candidates.isEmpty && connectable.isEmpty)
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Text(
                // Nothing open and nothing online: saying so beats an empty sheet.
                'No other session or online host to show alongside this one.',
                key: ValueKey('shell.split.none'),
                style: TextStyle(fontSize: 12),
              ),
            ),
          for (final session in candidates)
            ListTile(
              key: ValueKey('shell.split.pick.${session.id}'),
              dense: true,
              title: Text(session.serverName, style: const TextStyle(fontSize: 13)),
              onTap: () {
                vm.splitWith(session.id);
                Navigator.of(sheetContext).pop();
              },
            ),
          if (connectable.isNotEmpty) ...[
            const Divider(height: 1),
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Text(
                // Named so the two groups cannot be confused: one is already running, the other
                // costs a connection.
                'Connect into the second pane',
                key: ValueKey('shell.split.connectHeader'),
                style: TextStyle(fontSize: 11, color: OmniColors.textMuted),
              ),
            ),
            for (final server in connectable)
              ListTile(
                key: ValueKey('shell.split.connect.${server.id}'),
                dense: true,
                leading: const Icon(Icons.add_link, size: 18, color: OmniColors.cyan),
                title: Text(server.name, style: const TextStyle(fontSize: 13)),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  unawaited(vm.splitWithNewSession(server));
                },
              ),
          ],
        ],
      ),
    ),
  );
}
