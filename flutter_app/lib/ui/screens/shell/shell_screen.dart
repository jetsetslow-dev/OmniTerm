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
import '../../widgets/omni_components.dart';

/// The Shell screen, ported from `ShellScreen` in `ui/ShellScreen.kt`.
///
/// Three states: nothing to connect to, a host waiting for a connection, and a live terminal. The
/// screen never shows an empty black rectangle that looks like a working shell — every state says
/// what it is.
class ShellScreen extends StatelessWidget {
  const ShellScreen({super.key, this.licenseController});

  final LicenseController? licenseController;

  @override
  Widget build(BuildContext context) {
    final vm = context.watch<ShellViewModel>();
    final session = vm.current;
    final palette = terminalPaletteFor(context, vm.preferences.terminalTheme);

    return Container(
      color: palette.background,
      child: Column(
        children: [
          if (vm.sessions.isNotEmpty || session != null) _SessionBar(vm: vm),
          Expanded(
            child: session == null
                ? _ConnectPane(vm: vm, licenseController: licenseController)
                : vm.isSplit
                ? _SplitTerminals(vm: vm, first: session, second: vm.splitSession!)
                : _ActiveTerminal(vm: vm, session: session),
          ),
          if (session != null) TerminalKeyBar(viewModel: vm),
        ],
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
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('Left running', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
          Text(
            // Saying where they are, because "resumable" alone reads as a local draft rather than
            // work still executing on someone else's machine.
            'These are still running on their servers. Resuming attaches to one again.',
            style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 6),
          Flexible(
            child: ListView(
              shrinkWrap: true,
              children: [
                for (final row in vm.resumableSessions)
                  OmniCard(
                    key: ValueKey('shell.resumable.${row.tmuxName}'),
                    leftAccent: OmniColors.amber,
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                row.serverName,
                                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                              ),
                              Text(
                                // The name alone cannot be acted on: "left running 4m ago" and
                                // "left running last month" are the same card otherwise, and Forget
                                // is the button next to it.
                                '${row.tmuxName}  ·  ${describeSessionAge(row)}',
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 10,
                                  fontFamily: OmniFonts.mono,
                                  color: scheme.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ),
                        ),
                        TextButton(
                          key: ValueKey('shell.resumable.${row.tmuxName}.resume'),
                          onPressed: vm.isConnecting ? null : () => vm.resume(row),
                          child: const Text('Resume', style: TextStyle(fontSize: 12)),
                        ),
                        TextButton(
                          key: ValueKey('shell.resumable.${row.tmuxName}.forget'),
                          onPressed: () => _confirmForget(context, vm, row),
                          child: Text(
                            'Forget',
                            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
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
            label: const Text('Connect'),
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

class _SessionBar extends StatelessWidget {
  const _SessionBar({required this.vm});

  final ShellViewModel vm;

  @override
  Widget build(BuildContext context) {
    final current = vm.current;

    return Container(
      key: const ValueKey('shell.sessionBar'),
      height: 40,
      color: const Color(0xFF0B1017),
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: Row(
        children: [
          Expanded(
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [
                for (final session in vm.sessions)
                  _SessionChip(
                    session: session,
                    selected: session.id == current?.id,
                    onTap: () => vm.select(session.id),
                    onClose: () => _requestCloseSession(context, vm, session),
                  ),
              ],
            ),
          ),
          // Splitting needs a second session to show, so the control lives next to the one that
          // creates them.
          // A second pane needs something to put in it — another open session, or a host that can
          // be connected into it. Gating on open sessions alone hid the button in exactly the case
          // Kotlin supports: one terminal open, and another host a tap away.
          if (!vm.isSplit && (vm.sessions.length > 1 || vm.canConnectSecondPane))
            IconButton(
              key: const ValueKey('shell.split'),
              tooltip: 'Split the view',
              iconSize: 18,
              icon: const Icon(Icons.vertical_split, color: OmniColors.cyan),
              onPressed: () => _openSplitPicker(context, vm),
            ),
          if (vm.server != null && !vm.isConnecting)
            IconButton(
              key: const ValueKey('shell.newSession'),
              tooltip: 'New session',
              iconSize: 18,
              icon: const Icon(Icons.add, color: OmniColors.cyan),
              onPressed: vm.canConnect ? () => vm.connect(vm.server!) : null,
            ),
        ],
      ),
    );
  }
}

Future<void> _requestCloseSession(
  BuildContext context,
  ShellViewModel vm,
  ShellSession session,
) async {
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
  if (choice == 'leave') {
    vm.close(session);
  } else if (choice == 'disconnect') {
    if (persistent) {
      await vm.terminate(session);
    } else {
      vm.close(session);
    }
  }
}

class _SessionChip extends StatelessWidget {
  const _SessionChip({
    required this.session,
    required this.selected,
    required this.onTap,
    required this.onClose,
  });

  final ShellSession session;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: session,
    builder: (context, _) {
      // A dead session keeps its chip until it is dismissed: its scrollback is the only record
      // of why it died, and closing it automatically would erase that at the worst moment.
      final live = session.isOpen;
      final colour = live ? OmniColors.green : OmniColors.red;

      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 5, horizontal: 3),
        child: Tooltip(
          // The chip is too narrow for the age, and Kotlin shows it in the session dropdown. A
          // tooltip is the equivalent surface here: secondary detail, on demand, without spending
          // width that the session name needs.
          message:
              '${session.serverName}\n'
              'Started ${formatSessionAge(session.startedAt)} ago',
          child: InkWell(
            key: ValueKey('shell.session.${session.id}'),
            onTap: onTap,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              decoration: BoxDecoration(
                color: selected ? const Color(0xFF16202F) : Colors.transparent,
                borderRadius: BorderRadius.circular(4),
                border: Border.all(color: selected ? OmniColors.cyan : const Color(0xFF243044)),
              ),
              child: Row(
                children: [
                  Container(
                    width: 6,
                    height: 6,
                    decoration: BoxDecoration(color: colour, shape: BoxShape.circle),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    session.serverName,
                    style: const TextStyle(
                      fontFamily: OmniFonts.mono,
                      fontSize: 11,
                      color: Color(0xFFC8D4E8),
                    ),
                  ),
                  const SizedBox(width: 4),
                  InkWell(
                    key: ValueKey('shell.session.${session.id}.close'),
                    onTap: onClose,
                    child: const Icon(Icons.close, size: 13, color: Color(0xFF7C8AA5)),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    },
  );
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

  /// The last (session, pane focus, read-only) triple acted on, standing in for the key list of
  /// Kotlin's `LaunchedEffect` — see the comparison in [build].
  ({String id, bool focused, bool readOnly})? _lastFocusState;

  @override
  void dispose() {
    _input.dispose();
    _imeFocus.dispose();
    _keyFocus.dispose();
    super.dispose();
  }

  void _resetSmartInput() {
    _smartValue = '';
    _input.clear();
  }

  void _onCommit(BuildContext context, String text) {
    if (widget.vm.preferences.smartSwipeInput) {
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
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        key: const ValueKey('shell.pasteConfirm'),
        title: const Text('Paste into terminal?'),
        content: Text(
          '${text.runes.length} characters will be sent to the remote shell. '
          'Pasted lines may execute commands immediately.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Paste'),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) widget.vm.paste(text);
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
      if (widget.vm.preferences.smartSwipeInput) _resetSmartInput();
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
        if (widget.vm.preferences.smartSwipeInput) _resetSmartInput();
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
          _lastFocusState = focusState;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            if (focusState.focused && !focusState.readOnly) {
              _imeFocus.requestFocus();
            } else if (focusState.readOnly) {
              _imeFocus.unfocus();
            }
          });
        }
        return Column(
          children: [
            _TerminalStatusRow(vm: widget.vm, session: session),
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
                          enableSuggestions: preferences.smartSwipeInput,
                          textCapitalization: TextCapitalization.none,
                          keyboardType: preferences.smartSwipeInput
                              ? TextInputType.text
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
          if (!ended)
            _Toggle(
              label: 'RO',
              tooltip: 'Read-only: refuse every keystroke',
              active: session.readOnly,
              keyName: 'shell.readOnly',
              onTap: () => session.setReadOnly(!session.readOnly),
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

  String _status() => switch (session.endReason) {
    ShellSessionEnd.open =>
      session.readOnly
          ? 'READ ONLY · ${session.cols}×${session.rows} · drag to scroll'
          : '${session.serverName} · ${session.cols}×${session.rows}',
    // The exit status is the useful part of a clean exit, so it is shown rather than summarised.
    ShellSessionEnd.remoteExited =>
      'Session ended (exit ${session.exitStatus ?? 0}). Scrollback kept.',
    // Named as a connection problem, not as an exit: the remote may well still be running, and
    // telling the user their shell "ended" would be a lie they act on.
    ShellSessionEnd.disconnected => 'Connection lost. Scrollback kept.',
    ShellSessionEnd.closedByUser => 'Closed.',
  };
}

class _Toggle extends StatelessWidget {
  const _Toggle({
    required this.label,
    required this.tooltip,
    required this.active,
    required this.keyName,
    required this.onTap,
  });

  final String label;
  final String tooltip;
  final bool active;
  final String keyName;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: tooltip,
    child: InkWell(
      key: ValueKey(keyName),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: active ? OmniColors.amber.withValues(alpha: 0.2) : Colors.transparent,
          borderRadius: BorderRadius.circular(3),
          border: Border.all(color: active ? OmniColors.amber : const Color(0xFF243044)),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontFamily: OmniFonts.mono,
            fontSize: 10,
            color: active ? OmniColors.amber : const Color(0xFF7C8AA5),
          ),
        ),
      ),
    ),
  );
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
        child: _FocusablePane(paneIndex: 1, vm: vm, session: first, focused: true),
      ),
      const _SplitDivider(),
      Expanded(
        child: _FocusablePane(paneIndex: 2, vm: vm, session: second, focused: false),
      ),
    ];

    return Column(
      key: const ValueKey('shell.splitView'),
      children: [
        _SplitControls(vm: vm),
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

class _SplitControls extends StatelessWidget {
  const _SplitControls({required this.vm});

  final ShellViewModel vm;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const ValueKey('shell.splitControls'),
      height: 34,
      color: const Color(0xFF0B1017),
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        children: [
          TextButton.icon(
            key: const ValueKey('shell.split.axis'),
            icon: Icon(
              vm.splitStacked ? Icons.swap_vert : Icons.swap_horiz,
              size: 16,
              color: OmniColors.cyan,
            ),
            // Named for what the layout *is*, matching the Kotlin's own chips, so the button says
            // the current state rather than the action.
            label: Text(
              vm.splitStacked ? 'STACK' : 'COLS',
              style: const TextStyle(fontSize: 11, color: OmniColors.cyan),
            ),
            onPressed: vm.toggleSplitAxis,
          ),
          const Spacer(),
          TextButton(
            key: const ValueKey('shell.split.single'),
            onPressed: vm.unsplit,
            child: const Text('SINGLE', style: TextStyle(fontSize: 11, color: OmniColors.cyan)),
          ),
        ],
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
