import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../../data/app_database.dart';
import '../../../data/remote_models.dart';
import '../../../domain/host_display.dart';
import '../../../domain/ssh_keygen.dart';
import '../../../platform/distribution.dart';
import '../../../platform/license_controller.dart';
import '../../theme/colors.dart';
import '../../theme/typography.dart';
import '../../view_model/auth_keys_view_model.dart';
import '../../widgets/omni_components.dart';
import '../../widgets/license_gate.dart';

/// The Auth Keys tool, ported from `AuthKeysToolView` in `ui/ToolsScreen.kt`.
///
/// Three sections: credential profiles, SSH keys, and the pinned host keys. They belong together
/// because between them they answer "who am I, and who am I talking to".
class AuthKeysScreen extends StatefulWidget {
  const AuthKeysScreen({super.key, this.licenseController});

  final LicenseController? licenseController;

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
    final license = widget.licenseController;
    if (license == null) return _buildBody(context, vm, null, false);

    return ValueListenableBuilder<LicenseState>(
      valueListenable: license.state,
      builder: (context, state, _) {
        final atLimit =
            isPlayStoreDistribution && !state.unlocked && vm.profiles.length + vm.keys.length >= 1;
        return _buildBody(context, vm, license, atLimit);
      },
    );
  }

  Widget _buildBody(
    BuildContext context,
    AuthKeysViewModel vm,
    LicenseController? license,
    bool atLimit,
  ) {
    void gate() => showPremiumGate(
      context,
      controller: license!,
      title: 'Authentication method limit reached',
      message:
          'The free Play Store build supports one saved authentication method across '
          'credential profiles and SSH keys. Unlock OmniTerm to save more.',
    );
    return Stack(
      children: [
        ListView(
          key: const ValueKey('authKeys.list'),
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 88),
          children: [
            if (vm.status != null || vm.error != null) _MessageCard(vm: vm),
            if (atLimit)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: OmniCard(
                  key: const ValueKey('authKeys.limit'),
                  leftAccent: OmniColors.amber,
                  child: Row(
                    children: [
                      const Expanded(
                        child: Text(
                          'Free plan credential limit reached',
                          style: TextStyle(fontSize: 11),
                        ),
                      ),
                      TextButton(onPressed: gate, child: const Text('Unlock')),
                    ],
                  ),
                ),
              ),
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
                onPressed: atLimit ? gate : () => _openProfileEditor(context, vm),
                child: const Icon(Icons.badge_outlined),
              ),
              const SizedBox(width: 10),
              FloatingActionButton.small(
                key: const ValueKey('authKeys.generateKey'),
                heroTag: 'authKeys.generateKey',
                tooltip: 'Generate SSH key',
                onPressed: atLimit ? gate : () => _openKeyGenerator(context, vm),
                child: const Icon(Icons.auto_awesome),
              ),
              const SizedBox(width: 10),
              FloatingActionButton(
                key: const ValueKey('authKeys.importKey'),
                heroTag: 'authKeys.importKey',
                tooltip: 'Import SSH key',
                onPressed: atLimit ? gate : () => _openKeyImport(context, vm),
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

Future<void> _openKeyGenerator(BuildContext context, AuthKeysViewModel vm) async {
  final generated = await showDialog<GeneratedSshKey>(
    context: context,
    // Generation runs for seconds; dismissing mid-flight would strand the isolate's result with
    // nowhere to show the private key, which is only displayable once.
    barrierDismissible: false,
    builder: (_) => _KeyGenerateDialog(vm: vm),
  );
  if (generated == null || !context.mounted) return;
  await showDialog<void>(
    context: context,
    builder: (_) => _GeneratedKeyDialog(generated: generated),
  );
}

class _KeyGenerateDialog extends StatefulWidget {
  const _KeyGenerateDialog({required this.vm});

  final AuthKeysViewModel vm;

  @override
  State<_KeyGenerateDialog> createState() => _KeyGenerateDialogState();
}

class _KeyGenerateDialogState extends State<_KeyGenerateDialog> {
  final _alias = TextEditingController();
  String? _failure;
  bool _running = false;

  @override
  void dispose() {
    _alias.dispose();
    super.dispose();
  }

  Future<void> _generate() async {
    setState(() {
      _running = true;
      _failure = null;
    });
    final generated = await widget.vm.generateKey(alias: _alias.text);
    if (!mounted) return;
    if (generated == null) {
      setState(() {
        _running = false;
        _failure = widget.vm.error ?? 'Key generation failed.';
      });
      return;
    }
    Navigator.of(context).pop(generated);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      key: const ValueKey('authKeys.generate.dialog'),
      title: const Text('Generate cryptographic keypair'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            key: const ValueKey('authKeys.generate.alias'),
            controller: _alias,
            autofocus: true,
            enabled: !_running,
            decoration: omniInputDecoration(context, labelText: 'Key alias name'),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 10),
          Text(
            'OmniTerm generates a real $rsaKeyBits-bit RSA keypair on this device. The private key '
            'never leaves it — add the public key to the server to log in without a password.',
            style: const TextStyle(fontSize: 12, color: OmniColors.textMuted),
          ),
          if (_failure != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(
                _failure!,
                key: const ValueKey('authKeys.generate.error'),
                style: const TextStyle(color: OmniColors.red, fontSize: 12),
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
          // Keeps the dialog open with a spinner rather than dismissing, which looked like nothing
          // had happened during the seconds RSA generation takes.
          child: _running
              ? const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    SizedBox(width: 8),
                    Text('Generating…'),
                  ],
                )
              : const Text('Generate keys'),
        ),
      ],
    );
  }
}

/// Shows the generated material once, with the command that installs it on a server.
///
/// This is the only screen that ever displays the private key: it is stored encrypted and never read
/// back to the UI, so a user who does not copy it here cannot retrieve it later.
class _GeneratedKeyDialog extends StatelessWidget {
  const _GeneratedKeyDialog({required this.generated});

  final GeneratedSshKey generated;

  @override
  Widget build(BuildContext context) {
    final installCommand = authorizedKeysInstallCommand(generated.publicKey);
    return AlertDialog(
      key: const ValueKey('authKeys.generated.dialog'),
      title: const Text('Generated key'),
      content: SizedBox(
        width: double.maxFinite,
        // A scrolling Column rather than a ListView: every block must exist as soon as the dialog
        // does, so the install command is reachable (and copyable) without scrolling it into being.
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Warning: the private key is shown only now. Copy it if you need a backup.',
                style: TextStyle(color: OmniColors.red, fontSize: 12, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 10),
              _CopyBlock(
                label: 'Private key',
                value: generated.privateKey,
                copyLabel: 'Copy private key',
                valueKey: 'authKeys.generated.private',
              ),
              const SizedBox(height: 10),
              _CopyBlock(
                label: 'Public key',
                value: generated.publicKey,
                copyLabel: 'Copy public key',
                valueKey: 'authKeys.generated.public',
              ),
              const SizedBox(height: 10),
              const Text('Install on your server', style: TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 4),
              const Text(
                'The server only accepts this key after the PUBLIC key is added to '
                '~/.ssh/authorized_keys for the user you log in as. While password login still '
                'works, the easiest way is to run this in any terminal on this host:',
                style: TextStyle(fontSize: 12, color: OmniColors.textMuted),
              ),
              const SizedBox(height: 6),
              _CopyBlock(
                label: '',
                value: installCommand,
                copyLabel: 'Copy install command',
                valueKey: 'authKeys.generated.install',
              ),
            ],
          ),
        ),
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

class _CopyBlock extends StatelessWidget {
  const _CopyBlock({
    required this.label,
    required this.value,
    required this.copyLabel,
    required this.valueKey,
  });

  final String label;
  final String value;
  final String copyLabel;
  final String valueKey;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (label.isNotEmpty) Text(label, style: const TextStyle(fontWeight: FontWeight.bold)),
        Container(
          width: double.infinity,
          constraints: const BoxConstraints(maxHeight: 130),
          margin: const EdgeInsets.only(top: 4),
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            border: Border.all(color: Theme.of(context).dividerColor),
            borderRadius: BorderRadius.circular(4),
          ),
          child: SingleChildScrollView(
            child: SelectableText(
              value,
              key: ValueKey(valueKey),
              style: const TextStyle(fontFamily: OmniFonts.mono, fontSize: 10),
            ),
          ),
        ),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton.icon(
            key: ValueKey('$valueKey.copy'),
            icon: const Icon(Icons.copy, size: 16),
            label: Text(copyLabel),
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: value));
              if (!context.mounted) return;
              ScaffoldMessenger.of(
                context,
              ).showSnackBar(SnackBar(content: Text('$copyLabel — copied.')));
            },
          ),
        ),
      ],
    );
  }
}

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
