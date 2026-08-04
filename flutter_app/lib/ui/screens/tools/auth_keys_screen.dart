import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../data/app_database.dart';
import '../../../data/remote_models.dart';
import '../../../domain/host_display.dart';
import '../../theme/colors.dart';
import '../../theme/typography.dart';
import '../../view_model/auth_keys_view_model.dart';
import '../../widgets/omni_components.dart';

/// The Auth Keys tool, ported from `AuthKeysToolView` in `ui/ToolsScreen.kt`.
///
/// Three sections: credential profiles, SSH keys, and the pinned host keys. They belong together
/// because between them they answer "who am I, and who am I talking to".
class AuthKeysScreen extends StatefulWidget {
  const AuthKeysScreen({super.key});

  @override
  State<AuthKeysScreen> createState() => _AuthKeysScreenState();
}

class _AuthKeysScreenState extends State<AuthKeysScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) context.read<AuthKeysViewModel>().start();
    });
  }

  @override
  Widget build(BuildContext context) {
    final vm = context.watch<AuthKeysViewModel>();

    return Stack(
      children: [
        ListView(
          key: const ValueKey('authKeys.list'),
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 88),
          children: [
            if (vm.status != null || vm.error != null) _MessageCard(vm: vm),
            const SectionHeader(title: 'Credential profiles'),
            if (vm.profiles.isEmpty)
              const _EmptyNote(
                keyName: 'authKeys.profiles.empty',
                text:
                    'No profiles yet. A profile is a reusable username and credential, so several '
                    'hosts can share one login.',
              )
            else
              for (final profile in vm.profiles) _ProfileCard(vm: vm, profile: profile),
            const SizedBox(height: 16),
            const SectionHeader(title: 'SSH keys'),
            if (vm.keys.isEmpty)
              const _EmptyNote(
                keyName: 'authKeys.keys.empty',
                text: 'No keys yet. Import one to authenticate without a password.',
              )
            else
              for (final key in vm.keys) _KeyCard(vm: vm, sshKey: key),
            const SizedBox(height: 16),
            const SectionHeader(title: 'Trusted host keys'),
            _KnownHostsSection(vm: vm),
          ],
        ),
        Positioned(
          right: 16,
          bottom: 16,
          child: Row(
            children: [
              FloatingActionButton.small(
                key: const ValueKey('authKeys.addProfile'),
                heroTag: 'authKeys.addProfile',
                tooltip: 'New credential profile',
                onPressed: () => _openProfileEditor(context, vm),
                child: const Icon(Icons.badge_outlined),
              ),
              const SizedBox(width: 10),
              FloatingActionButton(
                key: const ValueKey('authKeys.importKey'),
                heroTag: 'authKeys.importKey',
                tooltip: 'Import SSH key',
                onPressed: () => _openKeyImport(context, vm),
                child: const Icon(Icons.key),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _MessageCard extends StatelessWidget {
  const _MessageCard({required this.vm});

  final AuthKeysViewModel vm;

  @override
  Widget build(BuildContext context) {
    final isError = vm.error != null;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: OmniCard(
        key: const ValueKey('authKeys.message'),
        leftAccent: isError ? OmniColors.red : OmniColors.green,
        child: Row(
          children: [
            Expanded(
              child: SelectionArea(
                child: Text(
                  vm.error ?? vm.status!,
                  style: TextStyle(fontSize: 12, color: isError ? OmniColors.red : null),
                ),
              ),
            ),
            IconButton(
              key: const ValueKey('authKeys.message.dismiss'),
              icon: const Icon(Icons.close, size: 16),
              onPressed: vm.dismissMessages,
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyNote extends StatelessWidget {
  const _EmptyNote({required this.keyName, required this.text});

  final String keyName;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      key: ValueKey(keyName),
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Text(
        text,
        style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant),
      ),
    );
  }
}

class _ProfileCard extends StatelessWidget {
  const _ProfileCard({required this.vm, required this.profile});

  final AuthKeysViewModel vm;
  final CredentialProfile profile;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: OmniCard(
        key: ValueKey('authKeys.profile.${profile.id}'),
        leftAccent: OmniColors.cyan,
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    profile.profileName,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  Text(
                    'User: ${profile.username} · Auth: ${profile.authType}',
                    style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
                  ),
                ],
              ),
            ),
            IconButton(
              key: ValueKey('authKeys.profile.${profile.id}.edit'),
              tooltip: 'Edit profile',
              icon: const Icon(Icons.edit, size: 18, color: OmniColors.cyan),
              onPressed: () => _openProfileEditor(context, vm, existing: profile),
            ),
            IconButton(
              key: ValueKey('authKeys.profile.${profile.id}.delete'),
              tooltip: 'Delete profile',
              icon: const Icon(Icons.delete_outline, size: 18, color: OmniColors.red),
              onPressed: () => _confirmDeleteProfile(context, vm, profile),
            ),
          ],
        ),
      ),
    );
  }
}

class _KeyCard extends StatelessWidget {
  const _KeyCard({required this.vm, required this.sshKey});

  final AuthKeysViewModel vm;
  final SshKey sshKey;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: OmniCard(
        key: ValueKey('authKeys.key.${sshKey.id}'),
        leftAccent: OmniColors.purple,
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    sshKey.alias,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  Text(
                    sshKey.keyType,
                    style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
                  ),
                  // Selectable because its whole purpose is comparison against what the host
                  // reports — and that means copying it.
                  SelectionArea(
                    child: Text(
                      sshKey.fingerprint,
                      style: TextStyle(
                        fontSize: 10,
                        fontFamily: OmniFonts.mono,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            IconButton(
              key: ValueKey('authKeys.key.${sshKey.id}.rename'),
              tooltip: 'Rename key',
              icon: const Icon(Icons.edit, size: 18, color: OmniColors.purple),
              onPressed: () => _openKeyRename(context, vm, sshKey),
            ),
            IconButton(
              key: ValueKey('authKeys.key.${sshKey.id}.delete'),
              tooltip: 'Delete key',
              icon: const Icon(Icons.delete_outline, size: 18, color: OmniColors.red),
              onPressed: () => _confirmDeleteKey(context, vm, sshKey),
            ),
          ],
        ),
      ),
    );
  }
}

class _KnownHostsSection extends StatelessWidget {
  const _KnownHostsSection({required this.vm});

  final AuthKeysViewModel vm;

  @override
  Widget build(BuildContext context) {
    // Listened to, not merely read: "Hide addresses" must repaint this list the moment it changes,
    // and a widget that reads a ChangeNotifier without subscribing never rebuilds.
    return ListenableBuilder(
      listenable: HostDisplay.instance,
      builder: (context, _) => _buildList(context),
    );
  }

  Widget _buildList(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    if (!vm.canManageTrust) {
      return const _EmptyNote(
        keyName: 'authKeys.trust.unavailable',
        text: 'Trusted host keys are not available in this build.',
      );
    }
    if (vm.knownHosts.isEmpty) {
      return const _EmptyNote(
        keyName: 'authKeys.trust.empty',
        text:
            'No hosts pinned yet. The first time you connect to a host, its key is shown for '
            'approval and remembered here.',
      );
    }

    return Column(
      key: const ValueKey('authKeys.trust.list'),
      children: [
        for (final host in vm.knownHosts)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: OmniCard(
              key: ValueKey('authKeys.trust.${host.host}'),
              leftAccent: OmniColors.green,
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          // Masked with everything else the toggle covers. The fingerprint below
                          // is deliberately *not* masked: it identifies the key, not the machine,
                          // and it is here to be compared against what the server reports.
                          HostDisplay.instance.sensitive(host.host),
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontWeight: FontWeight.bold,
                            fontFamily: OmniFonts.mono,
                            fontSize: 13,
                          ),
                        ),
                        SelectionArea(
                          child: Text(
                            '${host.keyType} · ${host.fingerprint}',
                            style: TextStyle(
                              fontSize: 10,
                              fontFamily: OmniFonts.mono,
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    key: ValueKey('authKeys.trust.${host.host}.revoke'),
                    tooltip: 'Forget this host key',
                    icon: const Icon(Icons.delete_outline, size: 18, color: OmniColors.red),
                    onPressed: () => _confirmRevoke(context, vm, host),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

// ── dialogs ───────────────────────────────────────────────────────────────────

Future<void> _openKeyImport(BuildContext context, AuthKeysViewModel vm) async {
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => _KeyImportSheet(vm: vm),
  );
}

class _KeyImportSheet extends StatefulWidget {
  const _KeyImportSheet({required this.vm});

  final AuthKeysViewModel vm;

  @override
  State<_KeyImportSheet> createState() => _KeyImportSheetState();
}

class _KeyImportSheetState extends State<_KeyImportSheet> {
  final _alias = TextEditingController();
  final _private = TextEditingController();
  final _public = TextEditingController();
  String? _failure;
  bool _saving = false;

  @override
  void dispose() {
    _alias.dispose();
    _private.dispose();
    _public.dispose();
    super.dispose();
  }

  Future<void> _import() async {
    setState(() {
      _saving = true;
      _failure = null;
    });
    final failure = await widget.vm.importKey(
      alias: _alias.text,
      privateKey: _private.text,
      publicKey: _public.text,
    );
    if (!mounted) return;
    setState(() {
      _saving = false;
      _failure = failure;
    });
    if (failure == null) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SizedBox(
        height: MediaQuery.of(context).size.height * 0.8,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 8, 0),
              child: Row(
                children: [
                  Expanded(
                    child: Text('Import SSH key', style: Theme.of(context).textTheme.titleLarge),
                  ),
                  IconButton(
                    key: const ValueKey('authKeys.import.close'),
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  TextField(
                    key: const ValueKey('authKeys.import.alias'),
                    controller: _alias,
                    decoration: omniInputDecoration(context, labelText: 'Alias'),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    key: const ValueKey('authKeys.import.private'),
                    controller: _private,
                    maxLines: 8,
                    style: const TextStyle(fontFamily: OmniFonts.mono, fontSize: 11),
                    decoration: omniInputDecoration(
                      context,
                      labelText: 'Private key',
                      hintText: '-----BEGIN OPENSSH PRIVATE KEY-----',
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    key: const ValueKey('authKeys.import.public'),
                    controller: _public,
                    maxLines: 3,
                    style: const TextStyle(fontFamily: OmniFonts.mono, fontSize: 11),
                    decoration: omniInputDecoration(
                      context,
                      labelText: 'Public key (optional)',
                      // Saying why it is worth pasting beats leaving "optional" to be guessed at.
                      hintText: 'Lets the fingerprint match what the server reports',
                    ),
                  ),
                  if (_failure != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Text(
                        _failure!,
                        key: const ValueKey('authKeys.import.error'),
                        style: const TextStyle(color: OmniColors.red, fontSize: 12),
                      ),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(12),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton(
                  key: const ValueKey('authKeys.import.save'),
                  onPressed: _saving ? null : _import,
                  child: Text(_saving ? 'Importing…' : 'Import'),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

Future<void> _openKeyRename(BuildContext context, AuthKeysViewModel vm, SshKey key) async {
  final name = await showDialog<String>(
    context: context,
    builder: (_) => _TextPromptDialog(
      dialogKey: 'authKeys.rename',
      title: 'Rename ${key.alias}',
      label: 'Alias',
      initial: key.alias,
      confirmLabel: 'Rename',
    ),
  );
  if (name == null) return;
  final failure = await vm.renameKey(key, name);
  if (failure != null && context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(failure)));
  }
}

Future<void> _confirmDeleteKey(BuildContext context, AuthKeysViewModel vm, SshKey key) async {
  final dependents = vm.hostsUsingKey(key);
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      key: const ValueKey('authKeys.deleteKey.dialog'),
      title: Text('Delete key "${key.alias}"?'),
      content: Text(
        // Naming the hosts is the point: "delete this key" gives no sense of the blast radius, and
        // the private material cannot be recovered.
        dependents.isEmpty
            ? 'The private key is deleted and cannot be recovered.'
            : 'These hosts authenticate with it and will stop connecting:\n\n'
                  '${dependents.map((s) => '• ${s.name}').join('\n')}\n\n'
                  'The private key is deleted and cannot be recovered.',
      ),
      actions: [
        TextButton(
          key: const ValueKey('authKeys.deleteKey.cancel'),
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: const Text('Cancel'),
        ),
        TextButton(
          key: const ValueKey('authKeys.deleteKey.confirm'),
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: const Text('Delete', style: TextStyle(color: OmniColors.red)),
        ),
      ],
    ),
  );
  if (confirmed ?? false) await vm.deleteKey(key);
}

Future<void> _confirmDeleteProfile(
  BuildContext context,
  AuthKeysViewModel vm,
  CredentialProfile profile,
) async {
  final dependents = vm.hostsUsingProfile(profile);
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      key: const ValueKey('authKeys.deleteProfile.dialog'),
      title: Text('Delete profile "${profile.profileName}"?'),
      content: Text(
        dependents.isEmpty
            ? 'The stored credentials are deleted.'
            : 'These hosts use it and will lose their credentials:\n\n'
                  '${dependents.map((s) => '• ${s.name}').join('\n')}',
      ),
      actions: [
        TextButton(
          key: const ValueKey('authKeys.deleteProfile.cancel'),
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: const Text('Cancel'),
        ),
        TextButton(
          key: const ValueKey('authKeys.deleteProfile.confirm'),
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: const Text('Delete', style: TextStyle(color: OmniColors.red)),
        ),
      ],
    ),
  );
  if (confirmed ?? false) await vm.deleteProfile(profile);
}

Future<void> _confirmRevoke(BuildContext context, AuthKeysViewModel vm, KnownHost host) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      key: const ValueKey('authKeys.revoke.dialog'),
      title: Text('Forget the key for ${HostDisplay.instance.sensitive(host.host)}?'),
      content: const Text(
        // Being explicit matters: forgetting a pin removes the protection that would otherwise
        // catch an interception, so the user should know the next connection asks again.
        'The next connection to this host will present its key for approval again.\n\n'
        'Do this when a host was legitimately rebuilt, or after you have verified a changed key '
        'through another channel.',
      ),
      actions: [
        TextButton(
          key: const ValueKey('authKeys.revoke.cancel'),
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: const Text('Cancel'),
        ),
        TextButton(
          key: const ValueKey('authKeys.revoke.confirm'),
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: const Text('Forget', style: TextStyle(color: OmniColors.red)),
        ),
      ],
    ),
  );
  if (confirmed ?? false) await vm.revokeKnownHost(host);
}

Future<void> _openProfileEditor(
  BuildContext context,
  AuthKeysViewModel vm, {
  CredentialProfile? existing,
}) async {
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => _ProfileSheet(vm: vm, existing: existing),
  );
}

class _ProfileSheet extends StatefulWidget {
  const _ProfileSheet({required this.vm, this.existing});

  final AuthKeysViewModel vm;
  final CredentialProfile? existing;

  @override
  State<_ProfileSheet> createState() => _ProfileSheetState();
}

class _ProfileSheetState extends State<_ProfileSheet> {
  late final _name = TextEditingController(text: widget.existing?.profileName ?? '');
  late final _username = TextEditingController(text: widget.existing?.username ?? '');
  final _password = TextEditingController();
  late String _authType = widget.existing?.authType ?? 'password';
  late String _keyAlias = widget.existing?.keyAlias ?? '';
  String? _failure;

  bool get _hasStoredPassword => (widget.existing?.password ?? '').isNotEmpty;

  @override
  void dispose() {
    _name.dispose();
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final failure = await widget.vm.saveProfile(
      existing: widget.existing,
      profileName: _name.text,
      username: _username.text,
      authType: _authType,
      password: _password.text,
      keyAlias: _keyAlias,
    );
    if (!mounted) return;
    if (failure == null) {
      Navigator.of(context).pop();
    } else {
      setState(() => _failure = failure);
    }
  }

  @override
  Widget build(BuildContext context) {
    final aliases = widget.vm.keys.map((k) => k.alias).toList();
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                widget.existing == null ? 'New credential profile' : 'Edit profile',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 12),
              TextField(
                key: const ValueKey('authKeys.profile.name'),
                controller: _name,
                decoration: omniInputDecoration(context, labelText: 'Profile name'),
              ),
              const SizedBox(height: 10),
              TextField(
                key: const ValueKey('authKeys.profile.username'),
                controller: _username,
                decoration: omniInputDecoration(context, labelText: 'Username'),
              ),
              const SizedBox(height: 10),
              SegmentedButton<String>(
                key: const ValueKey('authKeys.profile.authType'),
                segments: const [
                  ButtonSegment(value: 'password', label: Text('Password')),
                  ButtonSegment(value: 'key', label: Text('Key')),
                ],
                selected: {_authType},
                onSelectionChanged: (s) => setState(() => _authType = s.first),
              ),
              const SizedBox(height: 10),
              if (_authType == 'password')
                TextField(
                  key: const ValueKey('authKeys.profile.password'),
                  controller: _password,
                  obscureText: true,
                  decoration: omniInputDecoration(
                    context,
                    labelText: 'Password',
                    // Same rule as the host form: a stored secret is never rendered into a field,
                    // and an empty one means "unchanged".
                    hintText: _hasStoredPassword ? 'Saved — leave blank to keep' : null,
                  ),
                )
              else
                DropdownButtonFormField<String>(
                  key: const ValueKey('authKeys.profile.key'),
                  initialValue: aliases.contains(_keyAlias) ? _keyAlias : null,
                  decoration: omniInputDecoration(context, labelText: 'Key'),
                  items: [
                    for (final alias in aliases) DropdownMenuItem(value: alias, child: Text(alias)),
                  ],
                  onChanged: (v) => setState(() => _keyAlias = v ?? ''),
                ),
              if (_failure != null)
                Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Text(
                    _failure!,
                    key: const ValueKey('authKeys.profile.error'),
                    style: const TextStyle(color: OmniColors.red, fontSize: 12),
                  ),
                ),
              const SizedBox(height: 14),
              FilledButton(
                key: const ValueKey('authKeys.profile.save'),
                onPressed: _save,
                child: const Text('Save'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Asks for one value. Owns its controller so it dies with the dialog.
class _TextPromptDialog extends StatefulWidget {
  const _TextPromptDialog({
    required this.dialogKey,
    required this.title,
    required this.label,
    required this.confirmLabel,
    this.initial = '',
  });

  final String dialogKey;
  final String title;
  final String label;
  final String confirmLabel;
  final String initial;

  @override
  State<_TextPromptDialog> createState() => _TextPromptDialogState();
}

class _TextPromptDialogState extends State<_TextPromptDialog> {
  late final _controller = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      key: ValueKey('${widget.dialogKey}.dialog'),
      title: Text(widget.title),
      content: TextField(
        key: ValueKey('${widget.dialogKey}.field'),
        controller: _controller,
        autofocus: true,
        decoration: omniInputDecoration(context, labelText: widget.label),
      ),
      actions: [
        TextButton(
          key: ValueKey('${widget.dialogKey}.cancel'),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        TextButton(
          key: ValueKey('${widget.dialogKey}.confirm'),
          onPressed: () => Navigator.of(context).pop(_controller.text),
          child: Text(widget.confirmLabel),
        ),
      ],
    );
  }
}
