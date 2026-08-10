import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../data/app_database.dart';
import '../../../domain/host_display.dart';
import '../../../domain/network_share_form.dart';
import '../../../domain/share_scan.dart';
import '../../theme/colors.dart';
import '../../theme/typography.dart';
import '../../view_model/sftp_view_model.dart';
import '../../view_model/shares_view_model.dart';
import '../../widgets/omni_components.dart';

/// The Network Shares tab, ported from `NetworkSharesTab` in `ui/SftpScreen.kt`.
class SharesTab extends StatelessWidget {
  const SharesTab({super.key});

  @override
  Widget build(BuildContext context) {
    final vm = context.watch<SharesViewModel>();
    final scheme = Theme.of(context).colorScheme;

    return Column(
      children: [
        if (vm.status != null || vm.error != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            child: OmniCard(
              key: const ValueKey('shares.message'),
              leftAccent: vm.error != null ? OmniColors.red : OmniColors.green,
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      vm.error ?? vm.status!,
                      style: TextStyle(
                        fontSize: 12,
                        color: vm.error != null ? OmniColors.red : scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Dismiss',
                    key: const ValueKey('shares.message.dismiss'),
                    icon: const Icon(Icons.close, size: 16),
                    onPressed: vm.dismissMessages,
                  ),
                ],
              ),
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Network shares',
                      style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                    ),
                    Text(
                      'Saved SMB, FTP, SFTP, NFS and WebDAV endpoints',
                      style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
              if (vm.shares.isNotEmpty)
                TextButton.icon(
                  key: const ValueKey('shares.testAll'),
                  icon: const Icon(Icons.radar, size: 16),
                  label: const Text('Check all', style: TextStyle(fontSize: 12)),
                  onPressed: vm.testAll,
                ),
              FilledButton.icon(
                key: const ValueKey('shares.add'),
                icon: const Icon(Icons.add, size: 16),
                label: const Text('Add'),
                onPressed: () => _edit(context, vm, add: true),
              ),
            ],
          ),
        ),
        _ScanPanel(onAdd: (hit) => _edit(context, vm, fromScan: hit)),
        Expanded(
          child: vm.shares.isEmpty
              ? const Center(
                  child: Text(
                    'No network shares saved yet.',
                    key: ValueKey('shares.empty'),
                    style: TextStyle(fontSize: 12, color: OmniColors.textSecondary),
                  ),
                )
              : ListView.builder(
                  key: const ValueKey('shares.list'),
                  padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
                  itemCount: vm.shares.length,
                  itemBuilder: (context, index) => _ShareCard(
                    share: vm.shares[index],
                    checking: vm.isChecking(vm.shares[index].id),
                    onTest: () => vm.test(vm.shares[index]),
                    onBrowse: () => context.read<SftpViewModel>().openShare(vm.shares[index]),
                    onEdit: () => _edit(context, vm, share: vm.shares[index]),
                    onDelete: () => _confirmDelete(context, vm, vm.shares[index]),
                  ),
                ),
        ),
      ],
    );
  }

  Future<void> _edit(
    BuildContext context,
    SharesViewModel vm, {
    NetworkShare? share,
    bool add = false,
    ShareScanHit? fromScan,
  }) async {
    if (fromScan != null) {
      vm.startAddFromScan(fromScan);
    } else if (add) {
      vm.startAdd();
    } else if (share != null) {
      vm.startEdit(share);
    }
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) =>
          ChangeNotifierProvider<SharesViewModel>.value(value: vm, child: const _ShareForm()),
    );
    vm.cancelEdit();
  }

  Future<void> _confirmDelete(BuildContext context, SharesViewModel vm, NetworkShare share) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        key: const ValueKey('shares.delete.dialog'),
        title: Text('Delete "${share.name}"?'),
        content: const Text(
          // The blast radius, stated: "delete" next to a file browser reads as destructive.
          'Removes this saved share profile. Files on the share are not touched.',
          style: TextStyle(fontSize: 13),
        ),
        actions: [
          TextButton(
            key: const ValueKey('shares.delete.cancel'),
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            key: const ValueKey('shares.delete.confirm'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Delete', style: TextStyle(color: OmniColors.red)),
          ),
        ],
      ),
    );
    if (confirmed == true) await vm.delete(share);
  }
}

/// Finds share services on the local network, so a NAS does not have to be known before it can be
/// saved.
///
/// Collapsed by default: the tab's job is the saved shares, and a scanner permanently occupying the
/// top of it would push them off a phone screen.
class _ScanPanel extends StatefulWidget {
  const _ScanPanel({required this.onAdd});

  final void Function(ShareScanHit hit) onAdd;

  @override
  State<_ScanPanel> createState() => _ScanPanelState();
}

class _ScanPanelState extends State<_ScanPanel> {
  final _cidr = TextEditingController();
  bool _open = false;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      final vm = context.read<SharesViewModel>();
      await vm.loadScanSettings();
      if (!mounted || _cidr.text.isNotEmpty) return;
      // Prefilled from an address the user already saved, because the subnet they want is almost
      // always the one their existing shares are on. Left blank when there is nothing to infer
      // from, rather than guessing at 192.168.1.
      final prefix = vm.shares.map((s) => scanPrefixOf(s.address)).whereType<String>().firstOrNull;
      if (prefix != null) setState(() => _cidr.text = '$prefix.0/24');
      _loaded = true;
    });
  }

  @override
  void dispose() {
    _cidr.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final vm = context.watch<SharesViewModel>();
    final scheme = Theme.of(context).colorScheme;

    if (!_open) {
      return Align(
        alignment: Alignment.centerLeft,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
          child: TextButton.icon(
            key: const ValueKey('shares.scan.open'),
            icon: const Icon(Icons.wifi_find, size: 16),
            label: const Text('Find shares on my network', style: TextStyle(fontSize: 12)),
            onPressed: () => setState(() => _open = true),
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
      child: OmniCard(
        key: const ValueKey('shares.scan.panel'),
        leftAccent: OmniColors.cyan,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Expanded(
                  child: Text(
                    'Find shares on my network',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                  ),
                ),
                IconButton(
                  tooltip: 'Close scan',
                  key: const ValueKey('shares.scan.close'),
                  icon: const Icon(Icons.close, size: 16),
                  onPressed: () {
                    vm.clearScanHits();
                    setState(() => _open = false);
                  },
                ),
              ],
            ),
            Wrap(
              spacing: 6,
              children: [
                for (final protocol in allScanProtocols)
                  FilterChip(
                    key: ValueKey('shares.scan.protocol.$protocol'),
                    label: Text(protocol, style: const TextStyle(fontSize: 11)),
                    selected: vm.isScanProtocolEnabled(protocol),
                    onSelected: vm.scanning ? null : (_) => vm.toggleScanProtocol(protocol),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    key: const ValueKey('shares.scan.cidr'),
                    controller: _cidr,
                    enabled: !vm.scanning,
                    style: const TextStyle(fontFamily: OmniFonts.mono, fontSize: 12),
                    decoration: const InputDecoration(
                      isDense: true,
                      labelText: 'Subnet',
                      hintText: '192.168.1.0/24',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  key: const ValueKey('shares.scan.start'),
                  onPressed: vm.scanning ? null : () => vm.scanForShares(_cidr.text),
                  child: Text(vm.scanning ? 'Scanning…' : 'Scan'),
                ),
              ],
            ),
            if (vm.scanning) ...[
              const SizedBox(height: 6),
              // Determinate: a sweep of 254 addresses takes long enough that a spinner alone reads
              // as a hang.
              LinearProgressIndicator(value: vm.scanProgress, minHeight: 2),
            ],
            if (vm.scanStatus != null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  vm.scanStatus!,
                  key: const ValueKey('shares.scan.status'),
                  style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
                ),
              ),
            for (final hit in vm.scanHits)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Row(
                  key: ValueKey('shares.scan.hit.${hit.address}:${hit.port}'),
                  children: [
                    const Icon(Icons.lan, size: 14, color: OmniColors.cyan),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        hit.label,
                        style: const TextStyle(fontFamily: OmniFonts.mono, fontSize: 12),
                      ),
                    ),
                    TextButton(
                      key: ValueKey('shares.scan.add.${hit.address}:${hit.port}'),
                      onPressed: () => widget.onAdd(hit),
                      child: const Text('Add', style: TextStyle(fontSize: 12)),
                    ),
                  ],
                ),
              ),
            if (_loaded && vm.scanHits.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  // Said plainly, because an open port is weaker evidence than it looks.
                  'An open port means something is listening — not that these credentials will '
                  'work, or what the server exports. Fill in the path and sign-in details, then '
                  'use Check.',
                  style: TextStyle(fontSize: 10, color: scheme.onSurfaceVariant),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _ShareCard extends StatelessWidget {
  const _ShareCard({
    required this.share,
    required this.checking,
    required this.onTest,
    required this.onBrowse,
    required this.onEdit,
    required this.onDelete,
  });

  final NetworkShare share;
  final bool checking;
  final VoidCallback onTest;
  final VoidCallback onBrowse;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  static const _protocolColours = {
    ShareProtocol.smb: OmniColors.cyan,
    ShareProtocol.ftp: OmniColors.green,
    ShareProtocol.sftp: OmniColors.amber,
    ShareProtocol.nfs: OmniColors.purple,
    ShareProtocol.webdav: OmniColors.orange,
    ShareProtocol.custom: OmniColors.cyan,
  };

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final protocol = ShareProtocol.fromId(share.protocol);
    final colour = _protocolColours[protocol] ?? OmniColors.cyan;
    final unavailable = shareBrowseUnavailableReason(protocol);

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: OmniCard(
        key: ValueKey('shares.card.${share.id}'),
        leftAccent: colour,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                OmniTag(label: protocol.label, color: colour),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    share.name,
                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                _StatusDot(status: share.lastStatus, checking: checking),
              ],
            ),
            const SizedBox(height: 4),
            // Routed through HostDisplay: a share list is exactly the sort of screen that ends up
            // in a screenshot, and the URI carries the address.
            ListenableBuilder(
              listenable: HostDisplay.instance,
              builder: (context, _) => Text(
                shareUri(share, maskedAddress: HostDisplay.instance.sensitive(share.address)),
                key: ValueKey('shares.card.${share.id}.uri'),
                style: TextStyle(
                  fontSize: 11,
                  fontFamily: OmniFonts.mono,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
            const SizedBox(height: 2),
            Text(_authLabel(), style: TextStyle(fontSize: 10, color: scheme.onSurfaceVariant)),
            if (unavailable != null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  unavailable,
                  key: ValueKey('shares.card.${share.id}.noBrowse'),
                  style: const TextStyle(fontSize: 10, color: OmniColors.amber),
                ),
              ),
            const SizedBox(height: 4),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                if (unavailable == null)
                  TextButton(
                    key: ValueKey('shares.card.${share.id}.browse'),
                    onPressed: onBrowse,
                    child: const Text('Browse', style: TextStyle(fontSize: 12)),
                  ),
                TextButton(
                  key: ValueKey('shares.card.${share.id}.test'),
                  onPressed: checking ? null : onTest,
                  child: Text(
                    checking ? 'Checking…' : 'Check',
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
                TextButton(
                  key: ValueKey('shares.card.${share.id}.edit'),
                  onPressed: onEdit,
                  child: const Text('Edit', style: TextStyle(fontSize: 12)),
                ),
                TextButton(
                  key: ValueKey('shares.card.${share.id}.delete'),
                  onPressed: onDelete,
                  child: const Text(
                    'Delete',
                    style: TextStyle(fontSize: 12, color: OmniColors.red),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  String _authLabel() {
    if (share.anonymous) return 'anonymous';
    if (share.authProfileId != null) return 'credential profile #${share.authProfileId}';
    final parts = [share.workgroup, share.username].where((p) => p.trim().isNotEmpty);
    return parts.isEmpty ? 'credentials' : parts.join('\\');
  }
}

class _StatusDot extends StatelessWidget {
  const _StatusDot({required this.status, required this.checking});

  final String status;
  final bool checking;

  @override
  Widget build(BuildContext context) {
    if (checking) {
      return const SizedBox(
        width: 12,
        height: 12,
        child: CircularProgressIndicator(strokeWidth: 2, color: OmniColors.amber),
      );
    }
    // "unknown" is its own colour rather than borrowed from "unreachable": never checked and
    // checked-and-failed are different facts.
    final colour = switch (status) {
      'online' => OmniColors.green,
      'unreachable' => OmniColors.red,
      _ => OmniColors.textSecondary,
    };
    return Tooltip(
      message: status,
      child: Container(
        width: 10,
        height: 10,
        decoration: BoxDecoration(color: colour, shape: BoxShape.circle),
      ),
    );
  }
}

/// The add/edit sheet.
class _ShareForm extends StatelessWidget {
  const _ShareForm();

  @override
  Widget build(BuildContext context) {
    final vm = context.watch<SharesViewModel>();
    final draft = vm.draft;
    if (draft == null) return const SizedBox.shrink();

    final errors = draft.errors;
    final scheme = Theme.of(context).colorScheme;

    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              draft.id == 0 ? 'Add a network share' : 'Edit share',
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 6,
              children: [
                for (final protocol in ShareProtocol.values)
                  ChoiceChip(
                    key: ValueKey('shares.form.protocol.${protocol.id}'),
                    label: Text(protocol.label, style: const TextStyle(fontSize: 11)),
                    selected: draft.protocol == protocol,
                    onSelected: (_) => vm.updateDraft((d) => d.withProtocol(protocol)),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            _Field(
              fieldKey: 'name',
              label: 'Name',
              value: draft.name,
              error: errors['name'],
              onChanged: (v) => vm.updateDraft((d) => d.copyWith(name: v)),
            ),
            _Field(
              fieldKey: 'address',
              label: 'Address or hostname',
              value: draft.address,
              error: errors['address'],
              onChanged: (v) => vm.updateDraft((d) => d.copyWith(address: v)),
            ),
            _Field(
              fieldKey: 'port',
              label: 'Port',
              value: draft.port,
              error: errors['port'],
              keyboardType: TextInputType.number,
              onChanged: (v) => vm.updateDraft((d) => d.copyWith(port: v)),
            ),
            _Field(
              fieldKey: 'sharePath',
              label: draft.protocol == ShareProtocol.smb ? 'Share name' : 'Path (optional)',
              value: draft.sharePath,
              error: errors['sharePath'],
              onChanged: (v) => vm.updateDraft((d) => d.copyWith(sharePath: v)),
            ),
            SwitchListTile(
              key: const ValueKey('shares.form.anonymous'),
              contentPadding: EdgeInsets.zero,
              title: const Text('Connect anonymously', style: TextStyle(fontSize: 13)),
              value: draft.anonymous,
              onChanged: (v) => vm.updateDraft((d) => d.copyWith(anonymous: v)),
            ),
            if (!draft.anonymous) ...[
              if (draft.protocol == ShareProtocol.smb)
                _Field(
                  fieldKey: 'workgroup',
                  label: 'Workgroup or domain (optional)',
                  value: draft.workgroup,
                  onChanged: (v) => vm.updateDraft((d) => d.copyWith(workgroup: v)),
                ),
              _Field(
                fieldKey: 'username',
                label: 'Username',
                value: draft.username,
                error: errors['username'],
                onChanged: (v) => vm.updateDraft((d) => d.copyWith(username: v)),
              ),
              _Field(
                fieldKey: 'password',
                label: 'Password',
                value: draft.password,
                obscure: true,
                onChanged: (v) => vm.updateDraft((d) => d.copyWith(password: v)),
              ),
            ],
            if (draft.protocol == ShareProtocol.webdav)
              SwitchListTile(
                key: const ValueKey('shares.form.useHttps'),
                contentPadding: EdgeInsets.zero,
                title: const Text('Use HTTPS', style: TextStyle(fontSize: 13)),
                // Explicit rather than inferred from the port: Basic auth over plain http on a
                // nonstandard TLS port (Synology's 5006, say) would leak the password.
                subtitle: const Text(
                  'Not inferred from the port — a nonstandard TLS port with this off sends the '
                  'password in clear text.',
                  style: TextStyle(fontSize: 10),
                ),
                value: draft.useHttps,
                onChanged: (v) => vm.updateDraft((d) => d.copyWith(useHttps: v)),
              ),
            for (final (index, warning) in draft.warnings.indexed)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(Icons.warning_amber, size: 14, color: OmniColors.amber),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        warning,
                        key: ValueKey('shares.form.warning.$index'),
                        style: const TextStyle(fontSize: 11, color: OmniColors.amber),
                      ),
                    ),
                  ],
                ),
              ),
            const SizedBox(height: 8),
            Text(
              // §17: the app warns, it does not refuse. The user chose this server.
              'Warnings do not stop you saving — they are about the protocol, not about this host.',
              style: TextStyle(fontSize: 10, color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    key: const ValueKey('shares.form.cancel'),
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Cancel'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: FilledButton(
                    key: const ValueKey('shares.form.save'),
                    onPressed: draft.isValid
                        ? () async {
                            final saved = await vm.saveDraft();
                            if (saved && context.mounted) Navigator.of(context).pop();
                          }
                        : null,
                    child: const Text('Save'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// A labelled text field that reports its own validation message.
class _Field extends StatefulWidget {
  const _Field({
    required this.fieldKey,
    required this.label,
    required this.value,
    required this.onChanged,
    this.error,
    this.obscure = false,
    this.keyboardType,
  });

  final String fieldKey;
  final String label;
  final String value;
  final ValueChanged<String> onChanged;
  final String? error;
  final bool obscure;
  final TextInputType? keyboardType;

  @override
  State<_Field> createState() => _FieldState();
}

class _FieldState extends State<_Field> {
  late final TextEditingController _controller = TextEditingController(text: widget.value);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: TextField(
      key: ValueKey('shares.form.${widget.fieldKey}'),
      controller: _controller,
      obscureText: widget.obscure,
      enableSuggestions: !widget.obscure,
      autocorrect: false,
      keyboardType: widget.keyboardType,
      onChanged: widget.onChanged,
      decoration: InputDecoration(
        labelText: widget.label,
        // Shown only once the field has been touched — a form that opens covered in red says
        // the user has done something wrong before they have done anything at all.
        errorText: _controller.text.isEmpty && widget.value.isEmpty ? null : widget.error,
        isDense: true,
        border: const OutlineInputBorder(),
      ),
    ),
  );
}
