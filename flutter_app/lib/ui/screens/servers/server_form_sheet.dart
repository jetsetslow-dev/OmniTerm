import 'package:flutter/material.dart';

import '../../../data/app_database.dart';
import '../../theme/colors.dart';
import '../../widgets/omni_components.dart';
import 'server_form_state.dart';

/// Result of a connection test: null means success, otherwise a human-readable failure.
typedef ConnectionTester = Future<String?> Function(Server candidate);

/// The add / edit / duplicate sheet, ported from `AddServerSheet` in `ui/AppUi.kt`.
///
/// All of its rules live in [ServerFormState] — this is presentation only. The three tabs
/// (Connect / Auth / Advanced) match the Kotlin so a user's muscle memory survives the migration.
///
/// Every control carries a `ValueKey('serverForm.…')` for the Patrol suite.
class ServerFormSheet extends StatefulWidget {
  const ServerFormSheet({
    super.key,
    required this.mode,
    required this.onSave,
    this.source,
    this.onTestConnection,
    this.existingServers = const [],
    this.savedKeyAliases = const [],
  });

  final ServerFormMode mode;
  final Server? source;
  final Future<void> Function(Server server) onSave;
  final ConnectionTester? onTestConnection;
  final List<Server> existingServers;
  final List<String> savedKeyAliases;

  @override
  State<ServerFormSheet> createState() => _ServerFormSheetState();
}

class _ServerFormSheetState extends State<ServerFormSheet> {
  late final ServerFormState _form = ServerFormState(mode: widget.mode, source: widget.source);

  bool _testing = false;
  String? _testResult;
  bool _testPassed = false;
  String? _saveError;

  @override
  void dispose() {
    _form.dispose();
    super.dispose();
  }

  String get _title => switch (widget.mode) {
    ServerFormMode.add => 'Add host',
    ServerFormMode.edit => 'Edit host',
    ServerFormMode.duplicate => 'Duplicate host',
  };

  Future<void> _test() async {
    final tester = widget.onTestConnection;
    if (tester == null) return;
    setState(() {
      _testing = true;
      _testResult = null;
    });
    final error = await tester(_form.toServer());
    if (!mounted) return;
    setState(() {
      _testing = false;
      _testPassed = error == null;
      _testResult = error ?? 'Connection succeeded';
    });
    // Only a pass opens the save gate, and only for the configuration as it stands right now.
    if (error == null) _form.markConnectionTested();
  }

  Future<void> _save() async {
    final validation = _form.validationError;
    if (validation != null) {
      setState(() => _saveError = validation);
      return;
    }
    if (_form.requiresConnectionTest) {
      setState(
        () => _saveError = 'Test the connection before saving, so the host key can be verified.',
      );
      return;
    }
    await widget.onSave(_form.toServer());
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return DefaultTabController(
      length: 3,
      child: Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
        child: SizedBox(
          height: MediaQuery.of(context).size.height * 0.85,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 8, 0),
                child: Row(
                  children: [
                    Expanded(child: Text(_title, style: Theme.of(context).textTheme.titleLarge)),
                    IconButton(
                      key: const ValueKey('serverForm.close'),
                      icon: const Icon(Icons.close),
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                  ],
                ),
              ),
              const TabBar(
                key: ValueKey('serverForm.tabs'),
                tabs: [
                  Tab(text: 'Connect'),
                  Tab(text: 'Auth'),
                  Tab(text: 'Advanced'),
                ],
              ),
              Expanded(
                child: ListenableBuilder(
                  listenable: _form,
                  builder: (context, _) => TabBarView(
                    children: [
                      _ConnectTab(form: _form, existingServers: widget.existingServers),
                      _AuthTab(form: _form, savedKeyAliases: widget.savedKeyAliases),
                      _AdvancedTab(form: _form),
                    ],
                  ),
                ),
              ),
              if (_testResult != null)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                  child: Text(
                    _testResult!,
                    key: const ValueKey('serverForm.testResult'),
                    style: TextStyle(
                      color: _testPassed ? OmniColors.green : OmniColors.red,
                      fontSize: 12,
                    ),
                  ),
                ),
              if (_saveError != null)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                  child: Text(
                    _saveError!,
                    key: const ValueKey('serverForm.error'),
                    style: const TextStyle(color: OmniColors.red, fontSize: 12),
                  ),
                ),
              Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        key: const ValueKey('serverForm.test'),
                        onPressed: _testing || widget.onTestConnection == null ? null : _test,
                        icon: _testing
                            ? const SizedBox(
                                width: 14,
                                height: 14,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.wifi_tethering, size: 18),
                        label: Text(_testing ? 'Testing…' : 'Test connection'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: ListenableBuilder(
                        listenable: _form,
                        builder: (context, _) => FilledButton(
                          key: const ValueKey('serverForm.save'),
                          onPressed: _save,
                          child: Text(
                            _form.requiresConnectionTest ? 'Save (test first)' : 'Save',
                            style: TextStyle(color: scheme.onPrimary),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ConnectTab extends StatelessWidget {
  const _ConnectTab({required this.form, required this.existingServers});

  final ServerFormState form;
  final List<Server> existingServers;

  @override
  Widget build(BuildContext context) {
    return ListView(
      key: const ValueKey('serverForm.tab.connect'),
      padding: const EdgeInsets.all(16),
      children: [
        _Field(
          fieldKey: 'serverForm.name',
          label: 'Display name',
          initial: form.name,
          onChanged: (v) => form.update(() => form.name = v),
        ),
        _Field(
          fieldKey: 'serverForm.host',
          label: 'Host or IP',
          initial: form.host,
          onChanged: (v) => form.update(() => form.host = v),
        ),
        _Field(
          fieldKey: 'serverForm.port',
          label: 'Port',
          initial: form.port,
          keyboardType: TextInputType.number,
          onChanged: (v) => form.update(() => form.port = v),
        ),
        _Field(
          fieldKey: 'serverForm.username',
          label: 'Username',
          initial: form.username,
          onChanged: (v) => form.update(() => form.username = v),
        ),
        const SizedBox(height: 8),
        // Offering the labels already in use stops a typo silently forking a near-duplicate group.
        DropdownButtonFormField<String>(
          key: const ValueKey('serverForm.group'),
          initialValue: ServerFormState.groupOptions(existingServers).contains(form.group)
              ? form.group
              : 'Default',
          decoration: omniInputDecoration(context, labelText: 'Group'),
          items: [
            for (final group in ServerFormState.groupOptions(existingServers))
              DropdownMenuItem(value: group, child: Text(group)),
          ],
          onChanged: (v) => form.update(() => form.group = v ?? 'Default'),
        ),
        const SizedBox(height: 12),
        _ColourPicker(form: form),
      ],
    );
  }
}

class _AuthTab extends StatelessWidget {
  const _AuthTab({required this.form, required this.savedKeyAliases});

  final ServerFormState form;
  final List<String> savedKeyAliases;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListView(
      key: const ValueKey('serverForm.tab.auth'),
      padding: const EdgeInsets.all(16),
      children: [
        SegmentedButton<String>(
          key: const ValueKey('serverForm.authType'),
          segments: const [
            ButtonSegment(value: 'password', label: Text('Password')),
            ButtonSegment(value: 'key', label: Text('Key')),
            ButtonSegment(value: 'profile', label: Text('Profile')),
          ],
          selected: {form.authType},
          onSelectionChanged: (s) => form.update(() => form.authType = s.first),
        ),
        const SizedBox(height: 16),
        if (form.authType == 'password')
          _SecretField(
            fieldKey: 'serverForm.password',
            label: 'Password',
            hasStored: form.hasStoredPassword,
            forget: form.forgetPassword,
            onChanged: (v) => form.update(() => form.password = v),
            onForgetChanged: (v) => form.update(() => form.forgetPassword = v),
          ),
        if (form.authType == 'key')
          DropdownButtonFormField<String>(
            key: const ValueKey('serverForm.key'),
            initialValue: savedKeyAliases.contains(form.selectedKeyAlias)
                ? form.selectedKeyAlias
                : null,
            decoration: omniInputDecoration(context, labelText: 'Saved key'),
            items: [
              for (final alias in savedKeyAliases)
                DropdownMenuItem(value: alias, child: Text(alias)),
            ],
            onChanged: (v) => form.update(() => form.selectedKeyAlias = v ?? ''),
          ),
        if (form.authType == 'profile')
          Text(
            'Credential profiles are managed in Tools → Auth keys.',
            style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12),
          ),
      ],
    );
  }
}

class _AdvancedTab extends StatelessWidget {
  const _AdvancedTab({required this.form});

  final ServerFormState form;

  @override
  Widget build(BuildContext context) {
    return ListView(
      key: const ValueKey('serverForm.tab.advanced'),
      padding: const EdgeInsets.all(16),
      children: [
        _Field(
          fieldKey: 'serverForm.notes',
          label: 'Notes',
          initial: form.notes,
          onChanged: (v) => form.update(() => form.notes = v),
        ),
        _Field(
          fieldKey: 'serverForm.keepAlive',
          label: 'Keepalive (seconds)',
          initial: form.keepAlive,
          keyboardType: TextInputType.number,
          onChanged: (v) => form.update(() => form.keepAlive = v),
        ),
        SwitchListTile(
          key: const ValueKey('serverForm.compression'),
          title: const Text('SSH compression'),
          value: form.compression,
          onChanged: (v) => form.update(() => form.compression = v),
        ),
        SwitchListTile(
          key: const ValueKey('serverForm.persistentSession'),
          title: const Text('Persistent session (tmux)'),
          subtitle: const Text('Survives a dropped connection'),
          value: form.persistentSession,
          onChanged: (v) => form.update(() => form.persistentSession = v),
        ),
        SwitchListTile(
          key: const ValueKey('serverForm.agentForwarding'),
          title: const Text('Agent forwarding'),
          // Worth stating plainly: this grants the remote use of the key for the session.
          subtitle: const Text('Lets onward hops use your key. Off by default.'),
          value: form.agentForwarding,
          onChanged: (v) => form.update(() => form.agentForwarding = v),
        ),
        const SizedBox(height: 8),
        _SecretField(
          fieldKey: 'serverForm.sudoPassword',
          label: 'Sudo password',
          hasStored: form.hasStoredSudoPassword,
          forget: form.forgetSudoPassword,
          onChanged: (v) => form.update(() => form.sudoPassword = v),
          onForgetChanged: (v) => form.update(() => form.forgetSudoPassword = v),
        ),
        const SizedBox(height: 8),
        DropdownButtonFormField<String>(
          key: const ValueKey('serverForm.proxyType'),
          initialValue: form.proxyType,
          decoration: omniInputDecoration(context, labelText: 'Proxy'),
          items: const [
            DropdownMenuItem(value: 'none', child: Text('None')),
            DropdownMenuItem(value: 'http', child: Text('HTTP')),
            DropdownMenuItem(value: 'socks5', child: Text('SOCKS5')),
            DropdownMenuItem(value: 'ssh', child: Text('SSH jump host')),
          ],
          onChanged: (v) => form.update(() => form.proxyType = v ?? 'none'),
        ),
        if (form.proxyType != 'none') ...[
          _Field(
            fieldKey: 'serverForm.proxyHost',
            label: 'Proxy host',
            initial: form.proxyHost,
            onChanged: (v) => form.update(() => form.proxyHost = v),
          ),
          _Field(
            fieldKey: 'serverForm.proxyPort',
            label: 'Proxy port',
            initial: form.proxyPort,
            keyboardType: TextInputType.number,
            onChanged: (v) => form.update(() => form.proxyPort = v),
          ),
          _Field(
            fieldKey: 'serverForm.proxyUser',
            label: 'Proxy user',
            initial: form.proxyUser,
            onChanged: (v) => form.update(() => form.proxyUser = v),
          ),
          _SecretField(
            fieldKey: 'serverForm.proxyPassword',
            label: 'Proxy password',
            hasStored: form.hasStoredProxyPassword,
            forget: form.forgetProxyPassword,
            onChanged: (v) => form.update(() => form.proxyPassword = v),
            onForgetChanged: (v) => form.update(() => form.forgetProxyPassword = v),
          ),
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
  });

  final String fieldKey;
  final String label;
  final String initial;
  final ValueChanged<String> onChanged;
  final TextInputType? keyboardType;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextFormField(
        key: ValueKey(fieldKey),
        initialValue: initial,
        keyboardType: keyboardType,
        decoration: omniInputDecoration(context, labelText: label),
        onChanged: onChanged,
      ),
    );
  }
}

/// A password field that never shows what is stored.
///
/// When a secret is already saved the field stays empty and the hint says so; clearing it requires
/// the explicit "Forget" tick. See [ServerFormState] for why.
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextFormField(
          key: ValueKey(fieldKey),
          obscureText: true,
          decoration: omniInputDecoration(
            context,
            labelText: label,
            hintText: hasStored ? 'Saved — leave blank to keep' : null,
          ),
          onChanged: onChanged,
        ),
        if (hasStored)
          CheckboxListTile(
            key: ValueKey('$fieldKey.forget'),
            dense: true,
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            title: Text('Forget the saved $label', style: const TextStyle(fontSize: 12)),
            value: forget,
            onChanged: (v) => onForgetChanged(v ?? false),
          ),
      ],
    );
  }
}

class _ColourPicker extends StatelessWidget {
  const _ColourPicker({required this.form});

  final ServerFormState form;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      key: const ValueKey('serverForm.colours'),
      spacing: 8,
      children: [
        for (final (name, colour) in OmniColors.namedColors)
          ChoiceChip(
            key: ValueKey('serverForm.colour.$name'),
            label: Text(name),
            avatar: CircleAvatar(backgroundColor: colour, radius: 7),
            selected: form.serverColor == name,
            onSelected: (_) => form.update(() => form.serverColor = name),
          ),
      ],
    );
  }
}
