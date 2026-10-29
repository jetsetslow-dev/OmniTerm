import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../../data/app_database.dart';
import '../../../domain/host_display.dart';
import '../../../domain/input_validation.dart';
import '../../../domain/quick_connect.dart';
import '../../../l10n/app_localizations.dart';
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
import '../../../domain/tmux_session_name.dart';
import '../../view_model/shell_view_model.dart';
import 'saved_session_removal_dialog.dart';
import '../../widgets/terminal_key_bar.dart';
import '../../widgets/terminal_surface.dart';
import '../../widgets/terminal_options_dialog.dart';
import '../../widgets/terminal_transcript_sheet.dart';
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
                child: vm.isSplit
                    ? _SplitTerminals(
                        vm: vm,
                        first: vm.splitFirstSession,
                        second: vm.splitSecondSession,
                      )
                    : vm.isConnecting
                    ? _ConnectingView(phase: vm.connectPhase)
                    : session == null
                    ? _ConnectPane(vm: vm, licenseController: licenseController)
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
          final bodyMinimum = vm.isSplit
              ? (session == null
                        ? 0
                        : compactIme || session.readOnly
                        ? 42.0
                        : 80.0) +
                    (vm.splitStacked ? 2 : 1) * (80 + scaler.scale(28))
              : session == null
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
/// Kotlin's `isQuickConnectAvailable`: Quick connect is an Unlock OmniTerm feature on the free Play
/// Store build, where every host has to go through the saved list. There every entry point is
/// absent rather than shown and refused.
bool _quickConnectAvailable(LicenseController? licenseController) {
  final state = licenseController?.state.value;
  return state == null || !state.enabled || state.unlocked;
}

Future<void> _quickConnect(BuildContext context, ShellViewModel vm) async {
  final keyAliases = await vm.savedKeyAliases();
  final profiles = await vm.savedProfiles();
  if (!context.mounted) return;
  await showDialog<void>(
    context: context,
    builder: (_) => _QuickConnectDialog(
      vm: vm,
      savedKeyAliases: keyAliases,
      savedProfiles: profiles,
      savedServers: vm.savedServers,
    ),
  );
}

/// Kotlin's `QuickConnectSheet` in `ui/ShellScreen.kt`: built from the same pieces as the host form
/// — the same auth types, saved keys, credential profiles and proxy/jump options — so a connection
/// that works here works there, but nothing is written to the hosts list.
///
/// Add-host's "Test Connection first" is not repeated: here the connection *is* the action, and it
/// goes through the same connect path, host-key approval included.
class _QuickConnectDialog extends StatefulWidget {
  const _QuickConnectDialog({
    required this.vm,
    required this.savedKeyAliases,
    required this.savedProfiles,
    required this.savedServers,
  });

  final ShellViewModel vm;
  final List<String> savedKeyAliases;
  final List<CredentialProfile> savedProfiles;
  final List<Server> savedServers;

  @override
  State<_QuickConnectDialog> createState() => _QuickConnectDialogState();
}

class _QuickConnectDialogState extends State<_QuickConnectDialog> {
  final _host = TextEditingController();
  final _port = TextEditingController(text: '22');
  final _user = TextEditingController();
  final _password = TextEditingController();
  final _proxyHost = TextEditingController();
  final _proxyPort = TextEditingController();
  final _proxyUser = TextEditingController();
  final _proxyPassword = TextEditingController();
  String _authType = 'password';
  String _selectedKey = '';
  int? _selectedProfileId;
  String _proxyType = 'none';
  String _proxyKeyAlias = '';
  String? _errorText;

  @override
  void dispose() {
    for (final c in [
      _host,
      _port,
      _user,
      _password,
      _proxyHost,
      _proxyPort,
      _proxyUser,
      _proxyPassword,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  String? get _portIssue => portError(_port.text);
  String? get _proxyPortIssue => _proxyType != 'none' ? portError(_proxyPort.text) : null;

  void _connect() {
    setState(() => _errorText = null);
    // Field-level checks first so the message points at the offending field; the view model
    // repeats them because it is the funnel every ad-hoc connection goes through.
    final portIssue = _portIssue;
    if (portIssue != null) return setState(() => _errorText = 'SSH port: $portIssue');
    final proxyPortIssue = _proxyPortIssue;
    if (proxyPortIssue != null) return setState(() => _errorText = 'Proxy port: $proxyPortIssue');
    final password = _password.text;
    final error = widget.vm.quickConnect(
      QuickConnectInput(
        host: _host.text,
        port: int.tryParse(_port.text.trim()) ?? 22,
        username: _user.text.trim(),
        authType: _authType,
        password: _authType == 'password' && password.trim().isNotEmpty ? password : null,
        keyAlias: _authType == 'key' && _selectedKey.trim().isNotEmpty ? _selectedKey : null,
        profileId: _authType == 'profile' ? _selectedProfileId : null,
        proxyType: _proxyType,
        proxyHost: _proxyHost.text,
        proxyPort: int.tryParse(_proxyPort.text.trim()) ?? 0,
        proxyUser: _proxyUser.text,
        proxyPassword: _proxyPassword.text,
        proxyKeyAlias: _proxyKeyAlias.trim().isNotEmpty && _proxyType == 'ssh'
            ? _proxyKeyAlias
            : null,
      ),
    );
    // Rejected input only: the dialog stays open showing why. An accepted connection closes it and
    // reports its own outcome in the terminal.
    if (error != null) return setState(() => _errorText = error);
    Navigator.of(context).pop();
  }

  /// Saved hosts offered as jump hosts. A saved host's key carries over so the jump authenticates
  /// as it does when that host is connected to directly; its password never does, because it would
  /// be shown in a plain field.
  Future<void> _pickSavedJumpHost() async {
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    final picked = await showDialog<Server>(
      context: context,
      builder: (ctx) => AlertDialog(
        key: const ValueKey('shell.quick.jumpPicker'),
        title: const Text('Use a saved host as jump host'),
        content: widget.savedServers.isEmpty
            ? Text('No saved hosts to use as a jump host.', style: composeDialogBody())
            : SizedBox(
                width: double.maxFinite,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 300),
                  child: ListView(
                    shrinkWrap: true,
                    children: [
                      for (final candidate in widget.savedServers)
                        InkWell(
                          key: ValueKey('shell.quick.jumpPicker.${candidate.id}'),
                          onTap: () => Navigator.of(ctx).pop(candidate),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 8),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  candidate.name,
                                  style: composeDialogBody(fontWeight: FontWeight.bold),
                                ),
                                Text(
                                  '${HostDisplay.instance.userAtHost(candidate)}:${candidate.port}',
                                  style: composeDialogBody(fontSize: 11, color: muted),
                                ),
                              ],
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(AppLocalizations.of(ctx).cancel),
          ),
        ],
      ),
    );
    if (picked == null || !mounted) return;
    setState(() {
      _proxyHost.text = picked.host;
      _proxyPort.text = picked.port.toString();
      _proxyUser.text = picked.username;
      _proxyKeyAlias = picked.authKeyAlias ?? '';
      _proxyPassword.clear();
    });
  }

  Widget _chips(
    String group,
    Map<String, String> options,
    String selected,
    void Function(String) on,
  ) => Wrap(
    spacing: 6,
    children: [
      for (final MapEntry(:key, :value) in options.entries)
        FilterChip(
          key: ValueKey('shell.quick.$group.$key'),
          label: Text(value, style: composeDialogBody(fontSize: 11)),
          selected: selected == key,
          onSelected: (_) => setState(() => on(key)),
        ),
    ],
  );

  Widget _radioList<T>({
    required String listKey,
    required double maxHeight,
    required List<T> items,
    required bool Function(T) selected,
    required void Function(T) onTap,
    required Widget Function(T) label,
    required String Function(T) itemKey,
  }) => ConstrainedBox(
    key: ValueKey(listKey),
    constraints: BoxConstraints(maxHeight: maxHeight),
    child: ListView(
      shrinkWrap: true,
      children: [
        for (final item in items)
          InkWell(
            key: ValueKey('$listKey.${itemKey(item)}'),
            onTap: () => setState(() => onTap(item)),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                children: [
                  Icon(
                    selected(item) ? Icons.radio_button_checked : Icons.radio_button_unchecked,
                    size: 20,
                    color: selected(item)
                        ? Theme.of(context).colorScheme.primary
                        : Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 8),
                  Expanded(child: label(item)),
                ],
              ),
            ),
          ),
      ],
    ),
  );

  Widget _field(
    String key,
    TextEditingController controller,
    String label, {
    bool obscure = false,
    bool number = false,
    bool enabled = true,
    String? error,
    String? supporting,
  }) => TextField(
    key: ValueKey(key),
    controller: controller,
    obscureText: obscure,
    enabled: enabled,
    keyboardType: number
        ? TextInputType.number
        : obscure
        ? TextInputType.visiblePassword
        : null,
    decoration: omniInputDecoration(context, labelText: label).copyWith(
      errorText: error,
      errorStyle: const TextStyle(fontSize: 10),
      helperText: supporting,
      helperStyle: const TextStyle(fontSize: 10),
    ),
    onChanged: (_) => setState(() {}),
  );

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    final media = MediaQuery.of(context);
    final profileAuth = _authType == 'profile';
    final jump = _proxyType == 'ssh';
    return AlertDialog(
      key: const ValueKey('shell.quick.dialog'),
      scrollable: media.size.height - media.viewInsets.bottom < 420,
      title: const Text('Quick connect'),
      content: SizedBox(
        width: double.maxFinite,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 520),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              spacing: 8,
              children: [
                Text(
                  'Connects without saving. Nothing here is written to your hosts list.',
                  key: const ValueKey('shell.quick.note'),
                  style: composeDialogBody(fontSize: 11, color: muted),
                ),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  spacing: 8,
                  children: [
                    Expanded(flex: 2, child: _field('shell.quick.host', _host, l10n.hostnameOrIp)),
                    Expanded(
                      child: _field(
                        'shell.quick.port',
                        _port,
                        'Port',
                        number: true,
                        error: _portIssue,
                      ),
                    ),
                  ],
                ),
                _field(
                  'shell.quick.username',
                  _user,
                  'SSH username',
                  enabled: !profileAuth,
                  supporting: profileAuth ? 'Taken from the credential profile' : null,
                ),
                Text(
                  'Authentication',
                  style: composeDialogBody(fontSize: 12, fontWeight: FontWeight.bold),
                ),
                _chips(
                  'auth',
                  const {'password': 'Password', 'key': 'SSH key', 'profile': 'Profile'},
                  _authType,
                  (v) => _authType = v,
                ),
                switch (_authType) {
                  'password' => _field(
                    'shell.quick.password',
                    _password,
                    l10n.password,
                    obscure: true,
                  ),
                  'key' when widget.savedKeyAliases.isEmpty => Text(
                    'No saved SSH keys. Add one under Tools › Auth Keys.',
                    key: const ValueKey('shell.quick.noKeys'),
                    style: composeDialogBody(fontSize: 11, color: OmniColors.red),
                  ),
                  'key' => _radioList<String>(
                    listKey: 'shell.quick.key',
                    maxHeight: 120,
                    items: widget.savedKeyAliases,
                    selected: (alias) => _selectedKey == alias,
                    onTap: (alias) => _selectedKey = alias,
                    itemKey: (alias) => alias,
                    label: (alias) => Text(alias, style: composeDialogBody(fontSize: 13)),
                  ),
                  _ when widget.savedProfiles.isEmpty => Text(
                    'No credential profiles saved.',
                    key: const ValueKey('shell.quick.noProfiles'),
                    style: composeDialogBody(fontSize: 11, color: OmniColors.red),
                  ),
                  _ => _radioList<CredentialProfile>(
                    listKey: 'shell.quick.profile',
                    maxHeight: 120,
                    items: widget.savedProfiles,
                    selected: (profile) => _selectedProfileId == profile.id,
                    onTap: (profile) => _selectedProfileId = profile.id,
                    itemKey: (profile) => '${profile.id}',
                    label: (profile) => Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(profile.profileName, style: composeDialogBody(fontSize: 13)),
                        Text(
                          'User: ${profile.username}',
                          style: composeDialogBody(fontSize: 10, color: muted),
                        ),
                      ],
                    ),
                  ),
                },
                const Divider(height: 1),
                Text(
                  'Proxy / jump host',
                  style: composeDialogBody(fontSize: 12, fontWeight: FontWeight.bold),
                ),
                _chips(
                  'proxy',
                  const {'none': 'None', 'ssh': 'SSH jump', 'http': 'HTTP', 'socks5': 'SOCKS5'},
                  _proxyType,
                  (v) => _proxyType = v,
                ),
                if (_proxyType != 'none') ...[
                  if (jump && widget.savedServers.isNotEmpty)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton(
                        key: const ValueKey('shell.quick.useSavedHost'),
                        onPressed: _pickSavedJumpHost,
                        child: const Text('Use a saved host…', style: TextStyle(fontSize: 12)),
                      ),
                    ),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    spacing: 8,
                    children: [
                      Expanded(
                        flex: 2,
                        child: _field('shell.quick.proxyHost', _proxyHost, l10n.proxyHost),
                      ),
                      Expanded(
                        child: _field(
                          'shell.quick.proxyPort',
                          _proxyPort,
                          'Port',
                          number: true,
                          error: _proxyPortIssue,
                        ),
                      ),
                    ],
                  ),
                  _field(
                    'shell.quick.proxyUser',
                    _proxyUser,
                    jump ? 'Jump user (optional)' : 'Proxy user (optional)',
                  ),
                  _field(
                    'shell.quick.proxyPassword',
                    _proxyPassword,
                    jump ? 'Jump password (optional)' : 'Proxy password (optional)',
                    obscure: true,
                  ),
                  if (jump && widget.savedKeyAliases.isNotEmpty) ...[
                    Text(
                      'Jump host key (optional)',
                      style: composeDialogBody(fontSize: 11, color: muted),
                    ),
                    _radioList<String>(
                      listKey: 'shell.quick.jumpKey',
                      maxHeight: 100,
                      items: widget.savedKeyAliases,
                      selected: (alias) => _proxyKeyAlias == alias,
                      // Tap again to deselect: key auth on the jump host is optional.
                      onTap: (alias) => _proxyKeyAlias = _proxyKeyAlias == alias ? '' : alias,
                      itemKey: (alias) => alias,
                      label: (alias) => Text(alias, style: composeDialogBody(fontSize: 13)),
                    ),
                  ],
                ],
                if (_errorText != null)
                  Text(
                    _errorText!,
                    key: const ValueKey('shell.quick.error'),
                    style: composeDialogBody(fontSize: 12, color: OmniColors.red),
                  ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          key: const ValueKey('shell.quick.close'),
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.cancel),
        ),
        ListenableBuilder(
          listenable: widget.vm,
          builder: (context, _) => FilledButton(
            key: const ValueKey('shell.quick.connect'),
            onPressed: widget.vm.isConnecting ? null : _connect,
            child: const Text('Connect'),
          ),
        ),
      ],
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
            ? 'Add a server first.'
            : 'No online hosts. To SSH into an offline host anyway, use its connect button on the '
                  'Hosts tab.',
        error: vm.error,
        // With no saved hosts this is the only way out of this screen, so it is offered here and
        // not only from the header, which needs a selected host. Absent on the free build.
        action: _IfQuickConnectAvailable(
          licenseController: licenseController,
          child: Padding(
            padding: const EdgeInsets.only(top: 16),
            child: OutlinedButton.icon(
              key: const ValueKey('shell.empty.quickConnect'),
              onPressed: vm.canConnect ? () => _quickConnect(context, vm) : null,
              icon: const Icon(Icons.flash_on, size: 18),
              label: const Text("Quick connect (don't save)"),
            ),
          ),
        ),
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
    key: ValueKey('shell.resumable.${row.serverId}.${row.tmuxName}'),
    leftAccent: OmniColors.amber,
    child: LayoutBuilder(
      builder: (context, constraints) {
        final scheme = Theme.of(context).colorScheme;
        final metadata = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(row.serverName, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
            Text(
              '${displayTmuxSessionName(row.tmuxName)}  ·  ${describeSessionAge(row)}',
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
            key: ValueKey('shell.resumable.${row.serverId}.${row.tmuxName}.resume'),
            onPressed: vm.isConnecting ? null : () => vm.resume(row),
            child: const Text('Resume', style: TextStyle(fontSize: 12)),
          ),
          _RemoveSavedSessionButton(
            key: ValueKey('shell.resumable.${row.serverId}.${row.tmuxName}.remove'),
            onPressed: () => showSavedSessionRemovalDialog(context, vm, row),
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

/// Kotlin's red ✕ beside a saved session, which opens the Remove saved session dialog.
class _RemoveSavedSessionButton extends StatelessWidget {
  const _RemoveSavedSessionButton({super.key, required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: AppLocalizations.of(context).removeSavedSession,
    icon: const Icon(Icons.close, color: OmniColors.red),
    onPressed: onPressed,
  );
}

/// Shows [child] only while Quick connect is available, following licence changes.
class _IfQuickConnectAvailable extends StatelessWidget {
  const _IfQuickConnectAvailable({required this.licenseController, required this.child});

  final LicenseController? licenseController;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final controller = licenseController;
    if (controller == null) return child;
    return ValueListenableBuilder<LicenseState>(
      valueListenable: controller.state,
      builder: (context, _, _) =>
          _quickConnectAvailable(controller) ? child : const SizedBox.shrink(),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({super.key, required this.message, this.error, this.action});

  final String message;
  final String? error;
  final Widget? action;

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
            // Kotlin's text names no size, so it takes the screen's bodyLarge (16sp on 24sp lines),
            // in the shell chrome's muted colour for the current theme.
            style: composeBody(
              fontFamily: OmniFonts.mono,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          ?action,
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
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // Kotlin's ConnectPrompt: a bordered surfaceContainer card in the shell chrome colours, so it
    // reads correctly in the light theme as well as the dark one.
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Container(
          key: const ValueKey('shell.connect.card'),
          padding: const EdgeInsets.all(28),
          decoration: BoxDecoration(
            color: scheme.surfaceContainer,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: scheme.outline),
          ),
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
              const SizedBox(height: 14),
              Text(
                server.name,
                textAlign: TextAlign.center,
                style: composeBody(
                  fontFamily: OmniFonts.mono,
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: scheme.onSurface,
                ),
              ),
              // Routed through HostDisplay so "hide addresses" covers the terminal too.
              ListenableBuilder(
                listenable: HostDisplay.instance,
                builder: (context, _) => Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Text(
                    '${HostDisplay.instance.userAtHost(server)}:${server.port}',
                    key: const ValueKey('shell.connect.target'),
                    style: composeBody(fontSize: 14, color: scheme.onSurfaceVariant),
                  ),
                ),
              ),
              if (vm.error != null) ...[
                const SizedBox(height: 12),
                Container(
                  key: const ValueKey('shell.error.box'),
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  decoration: BoxDecoration(
                    color: OmniColors.red.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: OmniColors.red.withValues(alpha: 0.5)),
                  ),
                  child: Column(
                    children: [
                      Text(
                        'CONNECTION FAILED',
                        style: composeBody(
                          fontSize: 11,
                          fontFamily: OmniFonts.mono,
                          fontWeight: FontWeight.bold,
                          color: OmniColors.red,
                        ).copyWith(letterSpacing: 1),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        vm.error!,
                        key: const ValueKey('shell.error'),
                        textAlign: TextAlign.center,
                        style: composeBody(
                          fontSize: 12,
                          fontFamily: OmniFonts.mono,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 18),
              Material(
                color: scheme.primaryContainer,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                  side: BorderSide(color: scheme.primary),
                ),
                child: InkWell(
                  key: const ValueKey('shell.connect'),
                  borderRadius: BorderRadius.circular(8),
                  onTap: vm.canConnect
                      ? () => vm.connect(server, controlMode: vm.useControlMode)
                      : null,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 12),
                    child: Text(
                      vm.error == null ? 'Connect' : 'Retry',
                      style: composeBody(
                        fontWeight: FontWeight.bold,
                        color: scheme.onPrimaryContainer,
                      ).copyWith(letterSpacing: 1),
                    ),
                  ),
                ),
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
                        child: const Icon(
                          Icons.info_outline,
                          size: 14,
                          color: OmniColors.textMuted,
                        ),
                      ),
                    ],
                  ),
                ),
              _IfQuickConnectAvailable(
                licenseController: licenseController,
                child: Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: TextButton(
                    key: const ValueKey('shell.quickConnect'),
                    onPressed: vm.canConnect ? () => _quickConnect(context, vm) : null,
                    child: const Text(
                      'Quick connect to another host…',
                      style: TextStyle(fontSize: 12, color: OmniColors.cyan),
                    ),
                  ),
                ),
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
            ],
          ),
        ),
      ),
    );
  }
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
  /// The session a header action is working on, and what it is doing. Only that session's header
  /// shows it: switching hosts mid-disconnect must not carry the progress, or the disabled
  /// buttons, over to the other host.
  (String, String)? _work;
  String? get _workPhase {
    final work = _work;
    return work != null && work.$1 == vm.current?.id ? work.$2 : null;
  }

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
            onOpenSplit: !vm.isSplit
                ? null
                : (ids) {
                    final first = vm.connectableServers
                        .where((host) => host.id == ids[0])
                        .firstOrNull;
                    final second = vm.connectableServers
                        .where((host) => host.id == ids[1])
                        .firstOrNull;
                    if (first != null && second != null) {
                      unawaited(vm.openSplitForServers(first, second));
                    }
                  },
            leading: Text(
              vm.isSplit ? 'P${vm.focusedPane}' : 'TERM',
              style: const TextStyle(
                fontSize: 9,
                fontWeight: FontWeight.bold,
                fontFamily: OmniFonts.mono,
              ),
            ),
            // Kotlin's trailing content brings its own arrow, since it replaces the default one.
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  vm.isSplit ? 'FOCUSED' : 'CURRENT',
                  style: const TextStyle(fontSize: 9, fontWeight: FontWeight.bold),
                ),
                Icon(
                  Icons.arrow_drop_down,
                  color: scheme.onSurfaceVariant,
                  semanticLabel: 'Switch host',
                ),
              ],
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
                // Only a lost connection reconnects; a shell that exited on the server stays ended.
                if (session != null &&
                    session.endReason == ShellSessionEnd.disconnected &&
                    !session.reconnecting)
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
                            if (mounted) setState(() => _work = (session.id, phase));
                          },
                          onEnd: () {
                            if (mounted) setState(() => _work = null);
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
                // Kotlin's maxLines = 1 keeps the first wrapped line and clips the rest, so a
                // narrow "🔓 INPUT" chip shows just the lock — no ellipsis.
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.clip,
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
    final saved = vm.resumableSessions;
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
                detail: switch (session.tmuxName) {
                  final name? => displayTmuxSessionName(name),
                  null => 'Live SSH session',
                },
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
              // Host and name: two hosts can each have a session with the same name.
              key: ValueKey('shell.open.saved.${row.serverId}.${row.tmuxName}'),
              value: 'saved:${row.serverId}:${row.tmuxName}',
              child: Row(
                children: [
                  Expanded(
                    child: _TerminalSessionMenuLabel(
                      title: row.serverName,
                      detail: displayTmuxSessionName(row.tmuxName),
                      startedAt: row.createdAt,
                      backgroundedAt: row.backgroundedAt,
                    ),
                  ),
                  Builder(
                    builder: (menuContext) => _RemoveSavedSessionButton(
                      key: ValueKey('shell.open.saved.${row.serverId}.${row.tmuxName}.remove'),
                      onPressed: () =>
                          Navigator.of(menuContext).pop('remove:${row.serverId}:${row.tmuxName}'),
                    ),
                  ),
                ],
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
        if (_quickConnectAvailable(licenseController))
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
      final row = saved.where((r) => choice == 'saved:${r.serverId}:${r.tmuxName}').firstOrNull;
      if (row != null) await vm.resume(row);
    } else if (choice.startsWith('remove:')) {
      final row = saved.where((r) => choice == 'remove:${r.serverId}:${r.tmuxName}').firstOrNull;
      if (row != null) await showSavedSessionRemovalDialog(context, vm, row);
    } else if (choice == 'new') {
      if (vm.server != null) await vm.connect(vm.server!);
    } else if (choice == 'quick') {
      await _quickConnect(context, vm);
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
        paneChangeRevision: widget.session.paneChangeRevision,
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
                      // Kotlin's copy window hands focus and the keyboard back on dismiss, unless
                      // the session is read-only.
                      onOpenTranscript: () async {
                        await openTerminalTranscript(context, session);
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
              _status(AppLocalizations.of(context)),
              key: const ValueKey('shell.status'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontFamily: OmniFonts.mono,
                fontSize: 10,
                // A clean exit is not a failure, so it is not shown in the warning colour.
                color: ended && session.endReason != ShellSessionEnd.remoteExited
                    ? OmniColors.amber
                    : const Color(0xFF7C8AA5),
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

  String _status(AppLocalizations l10n) => session.reconnecting
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
          ShellSessionEnd.remoteExited => l10n.sessionEndedExit(session.exitStatus ?? 0),
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
  final ShellSession? first;
  final ShellSession? second;

  @override
  Widget build(BuildContext context) {
    final panes = [
      Expanded(
        child: _FocusablePane(paneIndex: 1, vm: vm, session: first, focused: vm.focusedPane == 1),
      ),
      const _SplitDivider(),
      Expanded(
        child: _FocusablePane(paneIndex: 2, vm: vm, session: second, focused: vm.focusedPane == 2),
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
  final ShellSession? session;
  final bool focused;

  @override
  Widget build(BuildContext context) {
    final terminal = session;
    // No gesture detector here on purpose — the terminal surface below claims the arena, so a
    // wrapper's tap would never fire. Focus is taken in `_ActiveTerminal`, where the tap lands.
    return Semantics(
      key: ValueKey(terminal == null ? 'shell.pane.empty.$paneIndex' : 'shell.pane.${terminal.id}'),
      container: true,
      explicitChildNodes: true,
      label: 'Terminal pane $paneIndex: ${terminal?.serverName ?? 'No session'}',
      value: focused ? 'Active terminal pane' : 'Inactive terminal pane',
      selected: focused,
      hint: 'Focus terminal pane $paneIndex',
      // This is an accessibility action, not a competing pointer handler. The terminal surface
      // keeps owning real taps while TalkBack can move the same focus that a tap would move.
      onTap: () => vm.focusSplitPane(paneIndex),
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border.all(color: focused ? OmniColors.cyan : Colors.transparent),
        ),
        child: terminal == null
            ? GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => vm.focusSplitPane(paneIndex),
                child: _EmptySplitPane(vm: vm, pane: paneIndex),
              )
            : Column(
                children: [
                  if (vm.isPaneConnecting(paneIndex)) ...[
                    const LinearProgressIndicator(),
                    Wrap(
                      children: [
                        Text(vm.connectPhase ?? 'Connecting…'),
                        TextButton(onPressed: vm.cancelConnect, child: const Text('Cancel')),
                      ],
                    ),
                  ],
                  Expanded(
                    child: _ActiveTerminal(vm: vm, session: terminal),
                  ),
                ],
              ),
      ),
    );
  }
}

class _EmptySplitPane extends StatelessWidget {
  const _EmptySplitPane({required this.vm, required this.pane});
  final ShellViewModel vm;
  final int pane;

  @override
  Widget build(BuildContext context) {
    final busy = vm.isPaneConnecting(pane);
    final awaiting = vm.isPaneAwaitingDecision(pane);
    final error = vm.paneError(pane);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (busy) const LinearProgressIndicator(),
        Expanded(
          child: ScrollConfiguration(
            behavior: const PopupScrollBehavior(popupsOnly: false),
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(12),
              child: Column(
                children: [
                  Text('Pane $pane', style: Theme.of(context).textTheme.titleSmall),
                  const SizedBox(height: 8),
                  if (busy) const CircularProgressIndicator(),
                  Text(
                    busy
                        ? vm.connectPhase ?? 'Connecting…'
                        : awaiting
                        ? 'Waiting for your connection decision…'
                        : error ?? vm.paneMessage(pane) ?? 'Choose a session for this pane.',
                    key: ValueKey('shell.pane.$pane.status'),
                    style: error == null ? null : const TextStyle(color: OmniColors.red),
                  ),
                ],
              ),
            ),
          ),
        ),
        Wrap(
          alignment: WrapAlignment.center,
          children: [
            if (busy || awaiting)
              TextButton(
                key: ValueKey('shell.pane.$pane.cancel'),
                onPressed: vm.cancelConnect,
                child: const Text('Cancel'),
              )
            else ...[
              if (vm.canRetryPane(pane))
                TextButton(
                  key: ValueKey('shell.pane.$pane.retry'),
                  onPressed: vm.isConnecting ? null : () => vm.retryPane(pane),
                  child: const Text('Retry'),
                ),
              TextButton(
                key: ValueKey('shell.pane.$pane.choose'),
                onPressed: vm.isConnecting
                    ? null
                    : () {
                        vm.focusSplitPane(pane);
                        _openSplitPicker(context, vm, pane: pane);
                      },
                child: const Text('Choose session'),
              ),
            ],
          ],
        ),
      ],
    );
  }
}

/// Pick a distinct existing terminal, saved tmux session, or a fresh connection for a fixed slot.
Future<void> _openSplitPicker(BuildContext context, ShellViewModel vm, {int pane = 2}) async {
  final candidates = vm.isSplit ? vm.splitCandidatesFor(pane) : vm.splitCandidates;
  final connectable = vm.connectableServers;
  final saved = vm.resumableSessions;
  await showModalBottomSheet<void>(
    context: context,
    useSafeArea: true,
    isScrollControlled: true,
    builder: (sheetContext) => SafeArea(
      child: SizedBox(
        height: MediaQuery.sizeOf(sheetContext).height * .75,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                'Choose session for pane $pane',
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
            Expanded(
              child: ScrollConfiguration(
                behavior: const PopupScrollBehavior(),
                child: ListView(
                  key: const ValueKey('shell.split.choices'),
                  padding: const EdgeInsets.only(bottom: 28),
                  children: [
                    if (candidates.isEmpty && connectable.isEmpty && saved.isEmpty)
                      const Padding(
                        padding: EdgeInsets.all(16),
                        child: Text(
                          'No session or online host is available.',
                          key: ValueKey('shell.split.none'),
                        ),
                      ),
                    for (final session in candidates)
                      ListTile(
                        key: ValueKey('shell.split.pick.${session.id}'),
                        title: Text(session.serverName),
                        subtitle: Text(switch (session.tmuxName) {
                          final name? => displayTmuxSessionName(name),
                          null => 'SSH terminal',
                        }),
                        onTap: () {
                          vm.enterSplit();
                          vm.assignSplitPane(pane, session.id, focus: false);
                          Navigator.of(sheetContext).pop();
                        },
                      ),
                    for (final row in saved)
                      ListTile(
                        key: ValueKey('shell.split.saved.${row.serverId}.${row.tmuxName}'),
                        title: Text(row.serverName),
                        subtitle: Text(displayTmuxSessionName(row.tmuxName)),
                        trailing: _RemoveSavedSessionButton(
                          key: ValueKey('shell.split.saved.${row.serverId}.${row.tmuxName}.remove'),
                          onPressed: () {
                            Navigator.of(sheetContext).pop();
                            unawaited(showSavedSessionRemovalDialog(context, vm, row));
                          },
                        ),
                        onTap: () {
                          Navigator.of(sheetContext).pop();
                          unawaited(vm.resumeIntoSplitPane(row, pane));
                        },
                      ),
                    if (connectable.isNotEmpty) ...[
                      const Divider(height: 1),
                      Padding(
                        padding: const EdgeInsets.all(12),
                        child: Text(
                          'Open a new terminal in pane $pane',
                          key: const ValueKey('shell.split.connectHeader'),
                        ),
                      ),
                      for (final server in connectable)
                        ListTile(
                          key: ValueKey('shell.split.connect.${server.id}'),
                          leading: const Icon(Icons.add_link, color: OmniColors.cyan),
                          title: Text(server.name),
                          subtitle: const Text('New SSH / tmux session'),
                          onTap: () {
                            Navigator.of(sheetContext).pop();
                            unawaited(vm.splitWithNewSession(server, pane: pane));
                          },
                        ),
                    ],
                  ],
                ),
              ),
            ),
            TextButton(
              key: const ValueKey('shell.split.cancel'),
              onPressed: () => Navigator.of(sheetContext).pop(),
              child: const Text('Cancel'),
            ),
          ],
        ),
      ),
    ),
  );
}
