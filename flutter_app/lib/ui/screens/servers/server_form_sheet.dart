import 'package:flutter/material.dart';

import '../../../data/app_database.dart';
import '../../../domain/host_display.dart';
import '../../../domain/input_validation.dart';
import '../../../domain/server_identity.dart';
import '../../../l10n/app_localizations.dart';
import '../../theme/colors.dart';
import '../../theme/typography.dart';
import '../../widgets/omni_components.dart';
import 'server_form_state.dart';

/// Result of a connection test: null means success, otherwise a human-readable failure.
typedef ConnectionTester = Future<String?> Function(Server candidate);

/// Persists the host; [createProfile] is Kotlin's "Save securely to Credential Store".
typedef ServerSaver = Future<void> Function(Server server, {bool createProfile});

/// Kotlin's green for "Connection OK" and the Credential Store note (`Color(0xFF10B981)`).
const _kotlinGreen = Color(0xFF10B981);

/// The add / edit / duplicate dialog, ported from `AddServerSheet` in `ui/AppUi.kt`.
///
/// Kotlin presents it as an AlertDialog wizard — Connection → Credentials → Advanced, advanced with
/// Next and left with Back — and this matches it control for control. The rules (secrets never
/// shown, the connection signature, step validation) live in [ServerFormState]; this is layout.
class ServerFormSheet extends StatefulWidget {
  const ServerFormSheet({
    super.key,
    required this.mode,
    required this.onSave,
    this.source,
    this.onTestConnection,
    this.existingServers = const [],
    this.savedKeyAliases = const [],
    this.savedProfiles = const [],
    this.prefillHost,
    this.prefillPort,
    this.suggestedName,
  });

  final ServerFormMode mode;
  final Server? source;
  final ServerSaver onSave;
  final ConnectionTester? onTestConnection;
  final List<Server> existingServers;
  final List<String> savedKeyAliases;
  final List<CredentialProfile> savedProfiles;
  final String? prefillHost;
  final int? prefillPort;
  final String? suggestedName;

  @override
  State<ServerFormSheet> createState() => _ServerFormSheetState();
}

class _ServerFormSheetState extends State<ServerFormSheet> {
  late final ServerFormState _form = ServerFormState(
    mode: widget.mode,
    source: widget.source,
    prefillHost: widget.prefillHost,
    prefillPort: widget.prefillPort,
    suggestedName: widget.suggestedName,
  );

  int _tab = 0;
  bool _testing = false;
  bool _saving = false;
  String? _testResult;
  String? _error;

  @override
  void dispose() {
    _form.dispose();
    super.dispose();
  }

  String get _title => switch (widget.mode) {
    ServerFormMode.duplicate => 'Duplicate Host',
    ServerFormMode.add => 'Add Linux Remote Host',
    ServerFormMode.edit => 'Edit Linux Remote Host',
  };

  Future<void> _test() async {
    final tester = widget.onTestConnection;
    if (tester == null) return;
    setState(() {
      _testing = true;
      _testResult = null;
    });
    // Bind the eventual OK to the fields as they were when the test started: edits made while it
    // runs still require a retest, exactly as Kotlin's signatureAtStart.
    final signatureAtStart = _form.connectionSignature;
    final error = await tester(_form.toServer());
    if (!mounted) return;
    setState(() {
      _testing = false;
      _testResult = error == null ? 'Connection OK' : 'Connection failed: $error';
    });
    if (error == null && _form.connectionSignature == signatureAtStart) {
      _form.markConnectionTested();
    }
  }

  void _next() {
    final failure = _form.stepError(_tab);
    setState(() {
      _error = failure;
      if (failure == null) _tab += 1;
    });
  }

  Future<void> _save() async {
    if (_saving) return;
    final candidate = _form.toServer();
    final identity = serverIdentity(candidate, widget.savedProfiles);
    for (final existing in [...widget.existingServers, if (widget.source != null) widget.source!]) {
      if (identity != null &&
          existing.id != candidate.id &&
          serverIdentity(existing, widget.savedProfiles) == identity) {
        setState(
          () => _error =
              'The same host, port, SSH user and authentication method already exist as '
              '"${existing.name}". Existing server unchanged.',
        );
        return;
      }
    }
    setState(() => _error = null);
    // An untested configuration can still be saved, but only deliberately (both apps): a host may be
    // reachable through a route this phone's check cannot reproduce, and the real SSH handshake still
    // asks to trust the host key on first connect.
    if (_form.requiresConnectionTest && !await _confirmUnverifiedSave()) return;
    final duplicate = _duplicateHost();
    if (duplicate != null && !await _confirmDuplicate(duplicate)) return;
    if (!mounted) return;
    setState(() => _saving = true);
    try {
      await widget.onSave(_form.toServer(), createProfile: _form.saveProfile);
      if (mounted) Navigator.of(context).pop();
    } catch (error) {
      if (mounted) setState(() => _error = error.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<bool> _confirmUnverifiedSave() async {
    final failedCheck = _testResult != null && _testResult != 'Connection OK';
    final l10n = AppLocalizations.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        key: const ValueKey('serverForm.unverified.dialog'),
        scrollable: true,
        title: Text(failedCheck ? 'Save after failed check?' : 'Save without testing?'),
        content: Text(
          failedCheck
              ? 'The automatic connection check did not succeed: $_testResult\n\n'
                    'You can still save this host and use SSH ANYWAY. OmniTerm will ask you to '
                    'approve its host key when an SSH server answers.'
              : 'This connection has not been tested. You can still save it and try SSH directly. '
                    'OmniTerm will ask you to approve the host key when an SSH server answers.',
        ),
        actions: [
          TextButton(
            key: const ValueKey('serverForm.unverified.review'),
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(l10n.review),
          ),
          FilledButton(
            key: const ValueKey('serverForm.unverified.saveAnyway'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(l10n.saveAnyway),
          ),
        ],
      ),
    );
    return confirmed ?? false;
  }

  /// An existing host already saved at the same address — new and duplicated hosts only.
  Server? _duplicateHost() {
    if (widget.mode == ServerFormMode.edit) return null;
    final address = _form.host.trim().toLowerCase();
    if (address.isEmpty) return null;
    for (final server in widget.existingServers) {
      if (server.id != (widget.source?.id ?? 0) && server.host.trim().toLowerCase() == address) {
        return server;
      }
    }
    return null;
  }

  Future<bool> _confirmDuplicate(Server duplicate) async {
    final display = HostDisplay.instance;
    final l10n = AppLocalizations.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        key: const ValueKey('serverForm.duplicate.dialog'),
        scrollable: true,
        title: Text(l10n.duplicateIpAddress),
        content: Text(l10n.duplicateHostBody(display.name(duplicate), display.host(duplicate))),
        actions: [
          TextButton(
            key: const ValueKey('serverForm.duplicate.review'),
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(l10n.review),
          ),
          FilledButton(
            key: const ValueKey('serverForm.duplicate.saveAnyway'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(l10n.saveAnyway),
          ),
        ],
      ),
    );
    return confirmed ?? false;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final media = MediaQuery.of(context);
    return AlertDialog(
      key: const ValueKey('serverForm.dialog'),
      // Kotlin keeps the title fixed and scrolls the steps (capped at 560dp). With the keyboard up
      // on a phone — or in landscape — the title and buttons alone may not fit, so the whole dialog
      // scrolls instead rather than overflowing.
      scrollable: media.size.height - media.viewInsets.bottom < 420,
      title: Text(_title),
      content: SizedBox(
        width: double.maxFinite,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 560),
          child: SingleChildScrollView(
            child: ListenableBuilder(
              listenable: _form,
              builder: (context, _) => Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  OmniTabRow(
                    key: const ValueKey('serverForm.tabs'),
                    labels: [l10n.connection, l10n.credentials, l10n.advanced],
                    selectedIndex: _tab,
                    onSelected: (i) => setState(() => _tab = i),
                    tabKeys: const [
                      ValueKey('serverForm.tab.connect'),
                      ValueKey('serverForm.tab.auth'),
                      ValueKey('serverForm.tab.advanced'),
                    ],
                  ),
                  const SizedBox(height: 16),
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Text(
                        _error!,
                        key: const ValueKey('serverForm.error'),
                        style: composeDialogBody(fontSize: 12, color: const Color(0xFFFF0000)),
                      ),
                    ),
                  switch (_tab) {
                    0 => _ConnectionStep(form: _form, existingServers: widget.existingServers),
                    1 => _CredentialsStep(
                      form: _form,
                      savedKeyAliases: widget.savedKeyAliases,
                      savedProfiles: widget.savedProfiles,
                      testing: _testing,
                      testResult: _testResult,
                      onTest: widget.onTestConnection == null || _testing ? null : _test,
                    ),
                    _ => _AdvancedStep(form: _form, savedKeyAliases: widget.savedKeyAliases),
                  },
                ],
              ),
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          key: const ValueKey('serverForm.back'),
          onPressed: _saving
              ? null
              : () => _tab > 0 ? setState(() => _tab -= 1) : Navigator.of(context).pop(),
          child: Text(_tab > 0 ? 'Back' : l10n.cancel),
        ),
        if (_tab < 2)
          FilledButton(
            key: const ValueKey('serverForm.next'),
            onPressed: _next,
            child: Text(l10n.next),
          )
        else
          FilledButton(
            key: const ValueKey('serverForm.save'),
            onPressed: _saving ? null : _save,
            child: _saving
                ? const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                      SizedBox(width: 8),
                      Text('Saving server…'),
                    ],
                  )
                : Text(widget.mode == ServerFormMode.edit ? 'Update Server' : 'Save Server'),
          ),
      ],
    );
  }
}

/// Kotlin `activeTab == 0`.
class _ConnectionStep extends StatelessWidget {
  const _ConnectionStep({required this.form, required this.existingServers});

  final ServerFormState form;
  final List<Server> existingServers;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final portFailure = portError(form.port);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 8,
      children: [
        _Field(
          fieldKey: 'serverForm.name',
          label: l10n.displayNameUnique,
          initial: form.name,
          onChanged: (v) => form.update(() => form.name = v),
        ),
        _Field(
          fieldKey: 'serverForm.host',
          label: l10n.ipAddressHostname,
          initial: form.host,
          keyboardType: TextInputType.url,
          onChanged: (v) => form.update(() => form.host = v),
        ),
        _Field(
          fieldKey: 'serverForm.port',
          label: l10n.sshPort,
          initial: form.port,
          keyboardType: TextInputType.number,
          errorText: portFailure,
          onChanged: (v) => form.update(() => form.port = v.replaceAll(RegExp(r'\D'), '')),
        ),
        _GroupField(form: form, groups: ServerFormState.groupOptions(existingServers)),
        Text(
          l10n.accentColor,
          style: composeDialogBody(fontSize: 12, color: scheme.onSurfaceVariant),
        ),
        Wrap(
          key: const ValueKey('serverForm.colours'),
          spacing: 10,
          runSpacing: 10,
          children: [
            for (final (name, colour) in OmniColors.namedColors)
              Semantics(
                label: name,
                selected: form.serverColor == name,
                button: true,
                child: GestureDetector(
                  key: ValueKey('serverForm.colour.$name'),
                  onTap: () => form.update(() => form.serverColor = name),
                  child: Container(
                    width: 28,
                    height: 28,
                    decoration: BoxDecoration(
                      color: colour,
                      shape: BoxShape.circle,
                      border: form.serverColor == name
                          ? Border.all(color: scheme.onSurface, width: 3)
                          : null,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ],
    );
  }
}

/// Kotlin's group field: free text, with an arrow that offers the labels already in use so a typo
/// cannot silently fork a near-duplicate group.
class _GroupField extends StatelessWidget {
  const _GroupField({required this.form, required this.groups});

  final ServerFormState form;
  final List<String> groups;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return _Field(
      fieldKey: 'serverForm.group',
      label: l10n.groupOptional,
      initial: form.group,
      onChanged: (v) => form.update(() => form.group = v),
      suffix: PopupMenuButton<String>(
        key: const ValueKey('serverForm.group.pick'),
        tooltip: 'Pick existing group',
        icon: const Icon(Icons.arrow_drop_down),
        onSelected: (g) => form.update(() => form.group = g),
        itemBuilder: (_) => [for (final g in groups) PopupMenuItem(value: g, child: Text(g))],
      ),
    );
  }
}

/// Kotlin `activeTab == 1`.
class _CredentialsStep extends StatelessWidget {
  const _CredentialsStep({
    required this.form,
    required this.savedKeyAliases,
    required this.savedProfiles,
    required this.testing,
    required this.testResult,
    required this.onTest,
  });

  final ServerFormState form;
  final List<String> savedKeyAliases;
  final List<CredentialProfile> savedProfiles;
  final bool testing;
  final String? testResult;
  final VoidCallback? onTest;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    final profileAuth = form.authType == 'profile';
    Widget radio(String value, String label) => Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Radio<String>(
          key: ValueKey('serverForm.authType.$value'),
          value: value,
          // ignore: deprecated_member_use
          groupValue: form.authType,
          // ignore: deprecated_member_use
          onChanged: (v) => form.update(() => form.authType = v ?? value),
        ),
        Flexible(child: Text(label, style: composeDialogBody())),
      ],
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 10,
      children: [
        _Field(
          fieldKey: 'serverForm.username',
          label: l10n.sshUsername,
          initial: form.username,
          enabled: !profileAuth,
          helperText: profileAuth ? l10n.providedByTheSelectedProfile : null,
          onChanged: (v) => form.update(() => form.username = v),
        ),
        Wrap(
          key: const ValueKey('serverForm.authType'),
          spacing: 16,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            radio('password', l10n.password),
            radio('key', l10n.sshPrivateKey),
            radio('profile', l10n.profile),
          ],
        ),
        if (form.authType == 'password') ...[
          _SecretField(
            fieldKey: 'serverForm.password',
            label: 'SSH Password',
            hasStored: form.hasStoredPassword,
            forget: form.forgetPassword,
            onChanged: (v) => form.update(() => form.password = v),
            onForgetChanged: (v) => form.update(() => form.forgetPassword = v),
          ),
          Row(
            children: [
              Checkbox(
                key: const ValueKey('serverForm.saveProfile'),
                value: form.saveProfile,
                onChanged: (v) => form.update(() => form.saveProfile = v ?? false),
              ),
              Expanded(
                child: Text(
                  l10n.saveSecurelyToCredentialStore,
                  style: composeDialogBody(fontSize: 12, color: muted),
                ),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(left: 12),
            child: Text(
              form.saveProfile
                  ? l10n.aNewCredentialsProfileWillBe
                  : l10n.eitherWayThePasswordIsStored,
              key: const ValueKey('serverForm.saveProfile.note'),
              style: composeDialogBody(
                fontSize: 11,
                color: form.saveProfile ? _kotlinGreen : muted,
              ),
            ),
          ),
        ] else if (form.authType == 'key') ...[
          if (savedKeyAliases.isEmpty)
            Text(l10n.noSshKeysSavedYetGo, style: composeDialogBody(fontSize: 12, color: muted))
          else ...[
            Text(l10n.selectKeypairAlias, style: composeDialogBody()),
            Wrap(
              key: const ValueKey('serverForm.key'),
              spacing: 8,
              runSpacing: 4,
              children: [
                for (final alias in savedKeyAliases)
                  FilterChip(
                    key: ValueKey('serverForm.key.$alias'),
                    label: Text(alias),
                    selected: form.selectedKeyAlias == alias,
                    onSelected: (_) => form.update(() => form.selectedKeyAlias = alias),
                  ),
              ],
            ),
          ],
        ] else ...[
          if (savedProfiles.isEmpty)
            Text(
              l10n.noCredentialsProfilesFoundGoTo,
              style: composeDialogBody(fontSize: 12, color: muted),
            )
          else ...[
            Text(l10n.selectCredentialsProfile, style: composeDialogBody()),
            SizedBox(
              key: const ValueKey('serverForm.profile'),
              height: 100,
              child: ListView(
                children: [
                  for (final profile in savedProfiles)
                    InkWell(
                      key: ValueKey('serverForm.profile.${profile.id}'),
                      onTap: () => form.update(() => form.selectedProfileId = profile.id),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: Row(
                          children: [
                            Radio<int>(
                              value: profile.id,
                              // ignore: deprecated_member_use
                              groupValue: form.selectedProfileId,
                              // ignore: deprecated_member_use
                              onChanged: (_) =>
                                  form.update(() => form.selectedProfileId = profile.id),
                            ),
                            const SizedBox(width: 8),
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(profile.profileName, style: composeDialogBody()),
                                Text(
                                  'User: ${profile.username}',
                                  style: composeDialogBody(fontSize: 11, color: muted),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ],
        // A REAL SSH connection + credential test, not a TCP ping.
        if (testResult != null)
          Text(
            testResult!,
            key: const ValueKey('serverForm.testResult'),
            style: composeDialogBody(
              fontSize: 12,
              color: testResult == 'Connection OK' ? _kotlinGreen : const Color(0xFFFF0000),
            ),
          ),
        Align(
          alignment: Alignment.centerRight,
          child: FilledButton(
            key: const ValueKey('serverForm.test'),
            onPressed: onTest,
            child: testing
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text(l10n.testConnection),
          ),
        ),
      ],
    );
  }
}

/// Kotlin `activeTab == 2`.
class _AdvancedStep extends StatelessWidget {
  const _AdvancedStep({required this.form, required this.savedKeyAliases});

  final ServerFormState form;
  final List<String> savedKeyAliases;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    Widget check(
      String key,
      bool value,
      ValueChanged<bool> onChanged,
      String title, [
      String? body,
    ]) => Row(
      children: [
        Checkbox(
          key: ValueKey('serverForm.$key'),
          value: value,
          onChanged: (v) => onChanged(v ?? false),
        ),
        Expanded(
          child: body == null
              ? Text(title, style: composeDialogBody())
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: composeDialogBody()),
                    Text(body, style: composeDialogBody(fontSize: 11, color: muted)),
                  ],
                ),
        ),
      ],
    );
    final jump = form.proxyType == 'ssh';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 8,
      children: [
        _Field(
          fieldKey: 'serverForm.notes',
          label: l10n.serverNotes,
          initial: form.notes,
          minLines: 2,
          onChanged: (v) => form.update(() => form.notes = v),
        ),
        Text(l10n.keepAliveInterval, style: composeDialogBody()),
        Wrap(
          key: const ValueKey('serverForm.keepAlive'),
          spacing: 8,
          runSpacing: 4,
          children: [
            for (final seconds in const ['10', '20', '30', '60', '120'])
              FilterChip(
                key: ValueKey('serverForm.keepAlive.$seconds'),
                label: Text('${seconds}s'),
                selected: form.keepAlive == seconds,
                onSelected: (_) => form.update(() => form.keepAlive = seconds),
              ),
          ],
        ),
        check(
          'compression',
          form.compression,
          (v) => form.update(() => form.compression = v),
          l10n.useSshPayloadCompression,
        ),
        check(
          'persistentSession',
          form.persistentSession,
          (v) => form.update(() => form.persistentSession = v),
          l10n.persistentSessionTmux,
          "Runs shells inside tmux so a dropped connection reconnects and long-running commands keep "
              "going. Requires tmux on the host — you'll be offered to install it on first connect.",
        ),
        check(
          'agentForwarding',
          form.agentForwarding,
          (v) => form.update(() => form.agentForwarding = v),
          l10n.forwardSshAgentSshA,
          'Lets onward SSH hops from this host authenticate with the key you connect with, without '
              'copying it to the server. Only enable for hosts you trust.',
        ),
        _SecretField(
          fieldKey: 'serverForm.sudoPassword',
          label: 'Sudo password (optional)',
          hasStored: form.hasStoredSudoPassword,
          forget: form.forgetSudoPassword,
          onChanged: (v) => form.update(() => form.sudoPassword = v),
          onForgetChanged: (v) => form.update(() => form.forgetSudoPassword = v),
        ),
        const SizedBox(height: 4),
        Text(l10n.proxySshJump, style: composeDialogBody(fontWeight: FontWeight.bold)),
        Wrap(
          key: const ValueKey('serverForm.proxyType'),
          spacing: 8,
          runSpacing: 6,
          children: [
            for (final (value, label) in const [
              ('none', 'None'),
              ('http', 'HTTP'),
              ('socks5', 'SOCKS5'),
              ('ssh', 'SSH Jump'),
            ])
              FilterChip(
                key: ValueKey('serverForm.proxyType.$value'),
                label: Text(label, style: const TextStyle(fontSize: 11)),
                selected: form.proxyType == value,
                onSelected: (_) => form.update(() => form.proxyType = value),
              ),
          ],
        ),
        if (form.proxyType != 'none') ...[
          Row(
            spacing: 8,
            children: [
              Expanded(
                flex: 2,
                child: _Field(
                  fieldKey: 'serverForm.proxyHost',
                  label: l10n.proxyHost,
                  initial: form.proxyHost,
                  onChanged: (v) => form.update(() => form.proxyHost = v),
                ),
              ),
              Expanded(
                child: _Field(
                  fieldKey: 'serverForm.proxyPort',
                  label: l10n.port,
                  initial: form.proxyPort,
                  keyboardType: TextInputType.number,
                  errorText: form.proxyPort.trim().isNotEmpty ? portError(form.proxyPort) : null,
                  onChanged: (v) =>
                      form.update(() => form.proxyPort = v.replaceAll(RegExp(r'\D'), '')),
                ),
              ),
            ],
          ),
          _Field(
            fieldKey: 'serverForm.proxyUser',
            label: jump ? 'Jump user (optional)' : 'Proxy user (optional)',
            initial: form.proxyUser,
            onChanged: (v) => form.update(() => form.proxyUser = v),
          ),
          _SecretField(
            fieldKey: 'serverForm.proxyPassword',
            label: jump ? 'Jump password (optional)' : 'Proxy password (optional)',
            hasStored: form.hasStoredProxyPassword,
            forget: form.forgetProxyPassword,
            onChanged: (v) => form.update(() => form.proxyPassword = v),
            onForgetChanged: (v) => form.update(() => form.forgetProxyPassword = v),
          ),
          if (jump) ...[
            Text(l10n.jumpHostKeyOptional, style: composeDialogBody(fontSize: 12)),
            if (savedKeyAliases.isEmpty)
              Text(l10n.noSshKeysSavedYetGo, style: composeDialogBody(fontSize: 12, color: muted))
            else
              Wrap(
                key: const ValueKey('serverForm.proxyKey'),
                spacing: 8,
                runSpacing: 4,
                children: [
                  for (final alias in savedKeyAliases)
                    FilterChip(
                      key: ValueKey('serverForm.proxyKey.$alias'),
                      label: Text(alias),
                      selected: form.proxyKeyAlias == alias,
                      // Tap again to deselect — key auth on the jump host is optional.
                      onSelected: (_) => form.update(
                        () => form.proxyKeyAlias = form.proxyKeyAlias == alias ? '' : alias,
                      ),
                    ),
                ],
              ),
          ],
        ],
      ],
    );
  }
}

class _Field extends StatelessWidget {
  const _Field({
    required this.fieldKey,
    required this.label,
    required this.initial,
    required this.onChanged,
    this.keyboardType,
    this.errorText,
    this.helperText,
    this.enabled = true,
    this.minLines,
    this.suffix,
  });

  final String fieldKey;
  final String label;
  final String initial;
  final ValueChanged<String> onChanged;
  final TextInputType? keyboardType;
  final String? errorText;
  final String? helperText;
  final bool enabled;
  final int? minLines;
  final Widget? suffix;

  @override
  Widget build(BuildContext context) => TextFormField(
    key: ValueKey(fieldKey),
    initialValue: initial,
    keyboardType: minLines != null ? TextInputType.multiline : keyboardType,
    minLines: minLines,
    maxLines: minLines == null ? 1 : null,
    enabled: enabled,
    decoration: omniInputDecoration(
      context,
      labelText: label,
    ).copyWith(errorText: errorText, helperText: helperText, suffixIcon: suffix),
    onChanged: onChanged,
  );
}

/// Kotlin's `StoredSecretField`: never displays a stored secret. With one saved and nothing typed,
/// it says leaving the field blank keeps it, and offers Forget to remove it on save.
class _SecretField extends StatelessWidget {
  const _SecretField({
    required this.fieldKey,
    required this.label,
    required this.hasStored,
    required this.forget,
    required this.onChanged,
    required this.onForgetChanged,
  });

  final String fieldKey;
  final String label;
  final bool hasStored;
  final bool forget;
  final ValueChanged<String> onChanged;
  final ValueChanged<bool> onForgetChanged;

  @override
  Widget build(BuildContext context) {
    return _SecretFieldBody(
      fieldKey: fieldKey,
      label: label,
      hasStored: hasStored,
      forget: forget,
      onChanged: onChanged,
      onForgetChanged: onForgetChanged,
    );
  }
}

class _SecretFieldBody extends StatefulWidget {
  const _SecretFieldBody({
    required this.fieldKey,
    required this.label,
    required this.hasStored,
    required this.forget,
    required this.onChanged,
    required this.onForgetChanged,
  });

  final String fieldKey;
  final String label;
  final bool hasStored;
  final bool forget;
  final ValueChanged<String> onChanged;
  final ValueChanged<bool> onForgetChanged;

  @override
  State<_SecretFieldBody> createState() => _SecretFieldBodyState();
}

class _SecretFieldBodyState extends State<_SecretFieldBody> {
  bool _empty = true;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        OmniPasswordField(
          fieldKey: ValueKey(widget.fieldKey),
          label: widget.label,
          onChanged: (v) {
            setState(() => _empty = v.isEmpty);
            widget.onChanged(v);
          },
        ),
        if (widget.hasStored && _empty)
          Row(
            children: [
              Expanded(
                child: Text(
                  widget.forget
                      ? 'Saved password will be removed when you save.'
                      : 'A password is saved (never shown here). Leave blank to keep it, or type to '
                            'replace.',
                  key: ValueKey('${widget.fieldKey}.stored'),
                  style: composeDialogBody(
                    fontSize: 11,
                    color: widget.forget
                        ? const Color(0xFFFF0000)
                        : Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              TextButton(
                key: ValueKey('${widget.fieldKey}.forget'),
                onPressed: () => widget.onForgetChanged(!widget.forget),
                child: Text(
                  widget.forget ? 'Keep' : 'Forget',
                  style: const TextStyle(fontSize: 11),
                ),
              ),
            ],
          ),
      ],
    );
  }
}
