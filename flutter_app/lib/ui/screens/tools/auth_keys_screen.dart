import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../../data/app_database.dart';
import '../../../data/remote_models.dart';
import '../../../domain/host_display.dart';
import '../../../domain/ssh_keygen.dart';
import '../../../platform/device_file_store.dart';
import '../../../platform/distribution.dart';
import '../../../platform/license_controller.dart';
import '../../../platform/sensitive_clipboard.dart';
import '../../navigation.dart';
import '../../theme/colors.dart';
import '../../theme/typography.dart';
import '../../view_model/auth_keys_view_model.dart';
import '../../widgets/omni_components.dart';
import '../../widgets/omni_confirm.dart';
import '../../widgets/popup_scroll_behavior.dart';

/// Kotlin's `credentialProfileLimitMessage()` for the single free Play Store credential.
const _credentialLimitMessage =
    'The free Play Store build supports 1 authentication method. Unlock OmniTerm to save '
    'unlimited credentials.';

/// The Auth Keys tool, ported from `AuthKeysToolView` in `ui/ToolsScreen.kt`: credential profiles,
/// SSH keys and the pinned host keys, with "+" offering the three ways to add a credential.
class AuthKeysScreen extends StatefulWidget {
  const AuthKeysScreen({super.key, this.licenseController, this.fileStore});

  final LicenseController? licenseController;

  /// Where "Load … from file" reads from; replaceable so tests need no system picker.
  final DeviceFileStore? fileStore;

  @override
  State<AuthKeysScreen> createState() => _AuthKeysScreenState();
}

class _AuthKeysScreenState extends State<AuthKeysScreen> {
  /// Kotlin's `authFeedback`: the outcome of the last add, import, generate or edit.
  String? _feedback;
  bool _feedbackOk = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) context.read<AuthKeysViewModel>().start();
    });
  }

  void _report(String? failure, AuthKeysViewModel vm) {
    if (!mounted) return;
    setState(() {
      _feedbackOk = failure == null;
      _feedback = failure ?? vm.status;
    });
  }

  @override
  Widget build(BuildContext context) {
    final vm = context.watch<AuthKeysViewModel>();
    final license = widget.licenseController;
    if (license == null) return _buildBody(context, vm, false);
    return ValueListenableBuilder<LicenseState>(
      valueListenable: license.state,
      builder: (context, state, _) => _buildBody(
        context,
        vm,
        isPlayStoreDistribution && !state.unlocked && vm.profiles.length + vm.keys.length >= 1,
      ),
    );
  }

  Widget _buildBody(BuildContext context, AuthKeysViewModel vm, bool atLimit) {
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    Widget sectionTitle(String text, double top) => Padding(
      padding: EdgeInsets.only(top: top),
      child: Text(text, style: composeBody(fontWeight: FontWeight.bold)),
    );

    final children = <Widget>[
      if (atLimit)
        Padding(
          key: const ValueKey('authKeys.limit'),
          padding: const EdgeInsets.only(top: 8),
          child: Text(
            _credentialLimitMessage,
            style: composeBody(fontSize: 12, color: OmniColors.amber),
          ),
        ),
      if (_feedback != null)
        Padding(
          key: const ValueKey('authKeys.message'),
          padding: const EdgeInsets.only(top: 8),
          child: Text(
            _feedback!,
            style: composeBody(
              fontSize: 12,
              color: _feedbackOk ? OmniColors.green : const Color(0xFFFF0000),
            ),
          ),
        ),
      sectionTitle('Credential Profiles (Username/Password)', 8),
      for (final profile in vm.profiles)
        _CredentialCard(
          cardKey: 'authKeys.profile.${profile.id}',
          accent: OmniColors.cyan,
          title: profile.profileName,
          detail: 'User: ${profile.username} · Auth: ${profile.authType}',
          onEdit: () => _editProfile(context, vm, profile),
          onDelete: () => _deleteProfile(context, vm, profile),
        ),
      sectionTitle('SSH Keys', 16),
      for (final key in vm.keys)
        _CredentialCard(
          cardKey: 'authKeys.key.${key.id}',
          accent: OmniColors.purple,
          title: key.alias,
          detail: 'Crypto: ${key.keyType} · Fingerprint: ${key.fingerprint}',
          onEdit: () => _editKey(context, vm, key),
          onDelete: () => _deleteKey(context, vm, key),
        ),
      // Listened to, so "Hide sensitive info" repaints the addresses the moment it changes.
      ListenableBuilder(
        listenable: HostDisplay.instance,
        builder: (context, _) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Padding(
              padding: EdgeInsets.only(top: 16, bottom: 4),
              child: SectionHeader(title: 'Trusted host keys'),
            ),
            if (!vm.canManageTrust || vm.knownHosts.isEmpty)
              Padding(
                key: const ValueKey('authKeys.trust.empty'),
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                child: Text(
                  'No trusted host keys yet.',
                  style: composeBody(fontSize: 12, color: muted),
                ),
              )
            else
              for (final host in vm.knownHosts) _knownHostCard(context, vm, host, muted),
          ],
        ),
      ),
    ];

    return ToolScaffold(
      title: 'Auth Keys & Profiles',
      keyPrefix: 'authKeys',
      onBack: () => context.read<NavigationController>().navigateTo(Screen.tools),
      onAdd: () => _chooseSource(context, vm),
      addEnabled: !atLimit,
      child: ScrollConfiguration(
        behavior: const PopupScrollBehavior(popupsOnly: false),
        child: ListView.separated(
          key: const ValueKey('authKeys.list'),
          padding: const EdgeInsets.all(12),
          itemCount: children.length,
          separatorBuilder: (_, _) => const SizedBox(height: 8),
          itemBuilder: (_, i) => children[i],
        ),
      ),
    );
  }

  Widget _knownHostCard(BuildContext context, AuthKeysViewModel vm, KnownHost host, Color muted) {
    final shown = HostDisplay.instance.sensitive(host.host);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: OmniCard(
        key: ValueKey('authKeys.trust.${host.host}'),
        leftAccent: OmniColors.amber,
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(shown, style: composeBody(fontSize: 13, fontWeight: FontWeight.bold)),
                  Text(
                    '${host.keyType} · ${host.fingerprint}',
                    maxLines: 2,
                    style: composeBody(fontSize: 10, color: muted),
                  ),
                ],
              ),
            ),
            IconButton(
              key: ValueKey('authKeys.trust.${host.host}.revoke'),
              tooltip: 'Remove trusted key',
              icon: const Icon(Icons.delete, color: Color(0xFFFF0000)),
              onPressed: () async {
                final confirmed = await showOmniConfirm(
                  context,
                  title: 'Remove trusted key?',
                  message:
                      'Remove the trusted SSH host key for $shown? The next connection will prompt '
                      'you to verify and pin the key again.',
                  confirmLabel: 'Remove',
                  destructive: true,
                  keyPrefix: 'authKeys.revoke',
                );
                if (confirmed) await vm.revokeKnownHost(host);
              },
            ),
          ],
        ),
      ),
    );
  }

  // ── flows ──────────────────────────────────────────────────────────────────────

  Future<void> _chooseSource(BuildContext context, AuthKeysViewModel vm) async {
    final choice = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        key: const ValueKey('authKeys.source.dialog'),
        scrollable: true,
        title: const Text('Add Authentication Source'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final (value, label) in const [
              ('profile', 'Profile (User/Pass)'),
              ('generate', 'Generate SSH Key'),
              ('import', 'Import SSH Key'),
            ])
              ListTile(
                key: ValueKey('authKeys.source.$value'),
                contentPadding: const EdgeInsets.symmetric(horizontal: 16),
                title: Text(label),
                onTap: () => Navigator.of(dialogContext).pop(value),
              ),
          ],
        ),
        actions: [
          TextButton(
            key: const ValueKey('authKeys.source.cancel'),
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Cancel'),
          ),
        ],
      ),
    );
    if (!context.mounted) return;
    switch (choice) {
      case 'profile':
        await _editProfile(context, vm, null);
      case 'generate':
        await _generateKey(context, vm);
      case 'import':
        await showDialog<void>(
          context: context,
          builder: (_) => _KeyMaterialDialog(
            vm: vm,
            fileStore: widget.fileStore ?? const DeviceFileStore(),
            onResult: (failure) => _report(failure, vm),
          ),
        );
    }
  }

  Future<void> _editProfile(
    BuildContext context,
    AuthKeysViewModel vm,
    CredentialProfile? profile,
  ) => showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) =>
        _ProfileDialog(vm: vm, existing: profile, onResult: (failure) => _report(failure, vm)),
  );

  Future<void> _editKey(BuildContext context, AuthKeysViewModel vm, SshKey key) => showDialog<void>(
    context: context,
    builder: (_) => _KeyMaterialDialog(
      vm: vm,
      existing: key,
      fileStore: widget.fileStore ?? const DeviceFileStore(),
      onResult: (failure) => _report(failure, vm),
    ),
  );

  Future<void> _generateKey(BuildContext context, AuthKeysViewModel vm) async {
    final result = await showDialog<(String, GeneratedSshKey?)>(
      context: context,
      // Generation runs for seconds; dismissing mid-flight would strand the only copy of the
      // private key the user will ever be shown.
      barrierDismissible: false,
      builder: (_) => _KeyGenerateDialog(vm: vm),
    );
    if (result == null || !context.mounted) return;
    final (alias, generated) = result;
    _report(generated == null ? (vm.error ?? 'Key generation failed.') : null, vm);
    if (generated == null) return;
    await showDialog<void>(
      context: context,
      builder: (_) => _GeneratedKeyDialog(alias: alias, generated: generated),
    );
  }

  Future<void> _deleteProfile(
    BuildContext context,
    AuthKeysViewModel vm,
    CredentialProfile profile,
  ) async {
    final confirmed = await showOmniConfirm(
      context,
      title: 'Delete profile?',
      message:
          'Delete credential profile "${profile.profileName}"? Hosts using it will lose these '
          'credentials.',
      confirmLabel: 'Delete',
      destructive: true,
      keyPrefix: 'authKeys.deleteProfile',
    );
    if (confirmed) await vm.deleteProfile(profile);
  }

  Future<void> _deleteKey(BuildContext context, AuthKeysViewModel vm, SshKey key) async {
    final confirmed = await showOmniConfirm(
      context,
      title: 'Delete key?',
      message:
          'Delete SSH key "${key.alias}" from OmniTerm? Hosts relying on it will no longer '
          'authenticate.',
      confirmLabel: 'Delete',
      destructive: true,
      keyPrefix: 'authKeys.deleteKey',
    );
    if (confirmed) await vm.deleteKey(key);
  }
}

/// A profile or key row: bold name over an 11sp detail line, with edit and delete icons.
class _CredentialCard extends StatelessWidget {
  const _CredentialCard({
    required this.cardKey,
    required this.accent,
    required this.title,
    required this.detail,
    required this.onEdit,
    required this.onDelete,
  });

  final String cardKey;
  final Color accent;
  final String title;
  final String detail;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) => OmniCard(
    key: ValueKey(cardKey),
    leftAccent: accent,
    inset: const EdgeInsets.all(16),
    child: Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: composeBody(fontWeight: FontWeight.bold)),
              Text(
                detail,
                style: composeBody(
                  fontSize: 11,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
        IconButton(
          key: ValueKey('$cardKey.edit'),
          tooltip: 'Edit',
          icon: Icon(Icons.edit, color: accent),
          onPressed: onEdit,
        ),
        IconButton(
          key: ValueKey('$cardKey.delete'),
          tooltip: 'Delete',
          icon: const Icon(Icons.delete, color: Color(0xFFFF0000)),
          onPressed: onDelete,
        ),
      ],
    ),
  );
}

Widget _busyLabel(bool busy, String idle, String working) => busy
    ? Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
          const SizedBox(width: 8),
          Text(working),
        ],
      )
    : Text(idle);

/// Kotlin's "Create Credential Profile" and "Edit Credential Profile" dialogs. New profiles are
/// username/password; editing a key profile keeps its key and says which one.
class _ProfileDialog extends StatefulWidget {
  const _ProfileDialog({required this.vm, required this.onResult, this.existing});

  final AuthKeysViewModel vm;
  final CredentialProfile? existing;
  final ValueChanged<String?> onResult;

  @override
  State<_ProfileDialog> createState() => _ProfileDialogState();
}

class _ProfileDialogState extends State<_ProfileDialog> {
  late final _name = TextEditingController(text: widget.existing?.profileName ?? '');
  late final _username = TextEditingController(text: widget.existing?.username ?? '');
  String _password = '';
  bool _saving = false;
  String? _failure;

  bool get _isKeyProfile => widget.existing != null && widget.existing!.authType != 'password';

  @override
  void initState() {
    super.initState();
    _name.addListener(_rebuild);
    _username.addListener(_rebuild);
  }

  void _rebuild() => setState(() {});

  @override
  void dispose() {
    _name.dispose();
    _username.dispose();
    super.dispose();
  }

  bool get _canSave =>
      !_saving &&
      _name.text.trim().isNotEmpty &&
      _username.text.trim().isNotEmpty &&
      (widget.existing != null || _password.isNotEmpty);

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _failure = null;
    });
    final existing = widget.existing;
    final failure = await widget.vm.saveProfile(
      existing: existing,
      profileName: _name.text,
      username: _username.text,
      authType: existing?.authType ?? 'password',
      password: _password,
      keyAlias: existing?.keyAlias ?? '',
    );
    widget.onResult(failure);
    if (!mounted) return;
    if (failure == null) {
      Navigator.of(context).pop();
    } else {
      setState(() {
        _saving = false;
        _failure = failure;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final editing = widget.existing != null;
    return PopScope(
      canPop: !_saving,
      child: AlertDialog(
        key: const ValueKey('authKeys.profile.dialog'),
        scrollable: true,
        title: Text(editing ? 'Edit Credential Profile' : 'Create Credential Profile'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: 10,
          children: [
            TextField(
              key: const ValueKey('authKeys.profile.name'),
              controller: _name,
              enabled: !_saving,
              decoration: omniInputDecoration(context, labelText: 'Profile Name'),
            ),
            TextField(
              key: const ValueKey('authKeys.profile.username'),
              controller: _username,
              enabled: !_saving,
              decoration: omniInputDecoration(context, labelText: 'Username'),
            ),
            if (_isKeyProfile)
              Text(
                "Key profile — bound to key '${widget.existing!.keyAlias ?? '?'}'.",
                style: composeDialogBody(
                  fontSize: 12,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              )
            else
              OmniPasswordField(
                fieldKey: const ValueKey('authKeys.profile.password'),
                label: editing ? 'Password (leave blank to keep current)' : 'Password',
                onChanged: (value) {
                  if (!_saving) setState(() => _password = value);
                },
              ),
            if (_failure != null)
              Text(
                _failure!,
                key: const ValueKey('authKeys.profile.error'),
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
          ],
        ),
        actions: [
          TextButton(
            key: const ValueKey('authKeys.profile.cancel'),
            onPressed: _saving ? null : () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const ValueKey('authKeys.profile.save'),
            onPressed: _canSave ? _save : null,
            child: _busyLabel(_saving, editing ? 'Save Changes' : 'Save Profile', 'Saving…'),
          ),
        ],
      ),
    );
  }
}

/// Kotlin's "Generate Cryptographic Keypair" dialog. Pops `(alias, key)` once generation ends,
/// success or not, as Kotlin closes it either way and reports through the screen's feedback line.
class _KeyGenerateDialog extends StatefulWidget {
  const _KeyGenerateDialog({required this.vm});

  final AuthKeysViewModel vm;

  @override
  State<_KeyGenerateDialog> createState() => _KeyGenerateDialogState();
}

class _KeyGenerateDialogState extends State<_KeyGenerateDialog> {
  final _alias = TextEditingController();
  bool _running = false;

  @override
  void dispose() {
    _alias.dispose();
    super.dispose();
  }

  Future<void> _generate() async {
    setState(() => _running = true);
    final alias = _alias.text;
    final generated = await widget.vm.generateKey(alias: alias);
    if (mounted) Navigator.of(context).pop((alias.trim(), generated));
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_running,
    child: AlertDialog(
      key: const ValueKey('authKeys.generate.dialog'),
      scrollable: true,
      title: const Text('Generate Cryptographic Keypair'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: 10,
        children: [
          TextField(
            key: const ValueKey('authKeys.generate.alias'),
            controller: _alias,
            enabled: !_running,
            decoration: omniInputDecoration(context, labelText: 'Key Alias Name'),
            onChanged: (_) => setState(() {}),
          ),
          Text(
            'OmniTerm will generate a real RSA $rsaKeyBits-bit SSH keypair and store the private '
            'key in the local key vault.',
            style: composeDialogBody(
              fontSize: 12,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: _running ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const ValueKey('authKeys.generate.submit'),
          onPressed: _alias.text.trim().isEmpty || _running ? null : _generate,
          child: _busyLabel(_running, 'Generate Keys', 'Generating…'),
        ),
      ],
    ),
  );
}

/// Kotlin's generated-key dialog: the only time the private key is ever shown.
class _GeneratedKeyDialog extends StatefulWidget {
  const _GeneratedKeyDialog({required this.alias, required this.generated});

  final String alias;
  final GeneratedSshKey generated;

  @override
  State<_GeneratedKeyDialog> createState() => _GeneratedKeyDialogState();
}

class _GeneratedKeyDialogState extends State<_GeneratedKeyDialog> {
  final SensitiveClipboard _clipboard = SensitiveClipboard();

  @override
  void dispose() {
    // Cancels the pending clear only; a key copied before closing must still paste.
    _clipboard.dispose();
    super.dispose();
  }

  Widget _readOnly(String key, String value, double height) => SizedBox(
    height: height,
    child: TextField(
      key: ValueKey(key),
      controller: TextEditingController(text: value),
      readOnly: true,
      expands: true,
      maxLines: null,
      style: const TextStyle(fontFamily: 'monospace', fontSize: 10),
      decoration: omniInputDecoration(context),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final generated = widget.generated;
    final install = authorizedKeysInstallCommand(generated.publicKey);
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    final bold = composeDialogBody(fontWeight: FontWeight.bold);
    return AlertDialog(
      key: const ValueKey('authKeys.generated.dialog'),
      scrollable: true,
      title: Text('Generated Key: ${widget.alias}'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 8,
        children: [
          Text(
            'Warning: Private key is shown only once. Please copy it now if you need it.',
            style: composeDialogBody(
              fontSize: 12,
              fontWeight: FontWeight.bold,
              color: const Color(0xFFFF0000),
            ),
          ),
          Text('Private Key', style: bold),
          _readOnly('authKeys.generated.private', generated.privateKey, 150),
          FilledButton(
            key: const ValueKey('authKeys.generated.private.copy'),
            onPressed: () =>
                _clipboard.copy(label: 'OmniTerm private key', text: generated.privateKey),
            child: const Text('Copy Private Key'),
          ),
          Text('Public Key', style: bold),
          _readOnly('authKeys.generated.public', generated.publicKey, 100),
          FilledButton(
            key: const ValueKey('authKeys.generated.public.copy'),
            onPressed: () => Clipboard.setData(ClipboardData(text: generated.publicKey)),
            child: const Text('Copy Public Key'),
          ),
          Text('Install on your server', style: bold),
          Text(
            'The server only accepts this key after the PUBLIC key is added to '
            '~/.ssh/authorized_keys for the user you log in as. While password login still works, '
            'the easiest way is to run this in any terminal on this host:',
            style: composeDialogBody(fontSize: 12, color: muted),
          ),
          _readOnly('authKeys.generated.install', install, 100),
          FilledButton(
            key: const ValueKey('authKeys.generated.install.copy'),
            onPressed: () => Clipboard.setData(ClipboardData(text: install)),
            child: const Text('Copy Install Command'),
          ),
          Text(
            'From a computer with ssh installed you can instead run: ssh-copy-id user@host',
            style: composeDialogBody(fontSize: 11, color: muted),
          ),
        ],
      ),
      actions: [
        FilledButton(
          key: const ValueKey('authKeys.generated.done'),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Done'),
        ),
      ],
    );
  }
}

/// Kotlin's "Import existing SSH Key" dialog, and with [existing] its "Edit SSH Key" dialog
/// (rename, optionally replacing the key material).
class _KeyMaterialDialog extends StatefulWidget {
  const _KeyMaterialDialog({
    required this.vm,
    required this.fileStore,
    required this.onResult,
    this.existing,
  });

  final AuthKeysViewModel vm;
  final DeviceFileStore fileStore;
  final ValueChanged<String?> onResult;
  final SshKey? existing;

  @override
  State<_KeyMaterialDialog> createState() => _KeyMaterialDialogState();
}

class _KeyMaterialDialogState extends State<_KeyMaterialDialog> {
  late final _alias = TextEditingController(text: widget.existing?.alias ?? '');
  final _private = TextEditingController();
  final _public = TextEditingController();
  bool _saving = false;

  /// Shown inside the dialog as well as on the screen: Kotlin keeps the dialog open on a failure
  /// but reports it only behind it, where it cannot be read until the dialog is dismissed.
  String? _failure;

  bool get _editing => widget.existing != null;

  @override
  void initState() {
    super.initState();
    _alias.addListener(_rebuild);
    _private.addListener(_rebuild);
  }

  void _rebuild() => setState(() {});

  @override
  void dispose() {
    _alias.dispose();
    _private.dispose();
    _public.dispose();
    super.dispose();
  }

  Future<void> _load(TextEditingController target) async {
    final path = await widget.fileStore.pick();
    if (path == null) return;
    try {
      target.text = await File(path).readAsString();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(
        context,
      )?.showSnackBar(SnackBar(content: Text('Could not read file: $e')));
    }
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _failure = null;
    });
    final existing = widget.existing;
    final failure = existing == null
        ? await widget.vm.importKey(
            alias: _alias.text,
            privateKey: _private.text,
            publicKey: _public.text,
          )
        : await widget.vm.updateKey(
            existing,
            alias: _alias.text,
            newPrivate: _private.text,
            newPublic: _public.text,
          );
    widget.onResult(failure);
    if (!mounted) return;
    if (failure == null) {
      Navigator.of(context).pop();
    } else {
      setState(() {
        _saving = false;
        _failure = failure;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    final bold = composeDialogBody(fontWeight: FontWeight.bold);
    Widget keyField(String key, TextEditingController c, String label, double height) => SizedBox(
      height: height,
      child: TextField(
        key: ValueKey(key),
        controller: c,
        expands: true,
        maxLines: null,
        textAlignVertical: TextAlignVertical.top,
        decoration: omniInputDecoration(context, labelText: label),
      ),
    );
    Widget loadButton(String key, String label, TextEditingController target) => SizedBox(
      width: double.infinity,
      child: OutlinedButton.icon(
        key: ValueKey(key),
        icon: const Icon(Icons.folder),
        label: Text(label),
        onPressed: () => _load(target),
      ),
    );
    final canSave =
        !_saving && _alias.text.trim().isNotEmpty && (_editing || _private.text.trim().isNotEmpty);

    return AlertDialog(
      key: ValueKey(_editing ? 'authKeys.editKey.dialog' : 'authKeys.import.dialog'),
      scrollable: true,
      title: Text(_editing ? 'Edit SSH Key' : 'Import existing SSH Key'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: 8,
        children: [
          if (!_editing)
            Text(
              'Only the private key is required — the type (RSA, OpenSSH, ed25519, ECDSA…) is '
              'detected automatically and the public key is derived from it. Add the public key '
              'only if you want to store it too.',
              style: composeDialogBody(fontSize: 12, color: muted),
            ),
          TextField(
            key: const ValueKey('authKeys.import.alias'),
            controller: _alias,
            decoration: omniInputDecoration(
              context,
              labelText: _editing ? 'Key Alias Name' : 'Key Custom Name',
            ),
          ),
          if (_editing)
            Text(
              'Renaming updates every host and profile that uses this key. Leave the key fields '
              'blank to keep the current key pair; paste a new private key to replace it.',
              style: composeDialogBody(fontSize: 12, color: muted),
            ),
          Text(
            _editing ? 'Replacement private key (optional)' : 'Private key (required)',
            style: bold,
          ),
          keyField(
            'authKeys.import.private',
            _private,
            '-----BEGIN ... PRIVATE KEY-----',
            _editing ? 120 : 130,
          ),
          loadButton('authKeys.import.loadPrivate', 'Load private key from file', _private),
          Text(
            _editing ? 'Replacement public key (optional)' : 'Public key (optional)',
            style: bold,
          ),
          keyField(
            'authKeys.import.public',
            _public,
            _editing
                ? 'ssh-… (leave blank to auto-derive)'
                : 'ssh-rsa AAAA… (leave blank to auto-derive)',
            _editing ? 80 : 90,
          ),
          if (!_editing)
            loadButton('authKeys.import.loadPublic', 'Load public key (.pub) from file', _public),
          if (_failure != null)
            Text(
              _failure!,
              key: const ValueKey('authKeys.import.error'),
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
        ],
      ),
      actions: [
        TextButton(
          key: const ValueKey('authKeys.import.cancel'),
          onPressed: _saving ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const ValueKey('authKeys.import.save'),
          onPressed: canSave ? _save : null,
          child: Text(_editing ? 'Save Changes' : 'Save Key'),
        ),
      ],
    );
  }
}
