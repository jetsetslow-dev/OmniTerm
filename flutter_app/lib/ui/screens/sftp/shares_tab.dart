import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../../data/app_database.dart';
import '../../../data/network/network_probe.dart';
import '../../../domain/host_display.dart';
import '../../../domain/input_validation.dart';
import '../../../l10n/app_localizations.dart';
import '../../../domain/network_share_form.dart';
import '../../../domain/share_scan.dart';
import '../../theme/colors.dart';
import '../../theme/typography.dart';
import '../../view_model/sftp_view_model.dart';
import '../../view_model/network_view_model.dart';
import '../../view_model/shares_view_model.dart';
import '../../widgets/omni_components.dart';

/// The Network Shares tab, ported from `NetworkSharesTab` in `ui/SftpScreen.kt`.
class SharesTab extends StatelessWidget {
  const SharesTab({super.key});

  @override
  Widget build(BuildContext context) {
    final vm = context.watch<SharesViewModel>();
    final scheme = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context);

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
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(l10n.networkShares, style: composeBody(fontWeight: FontWeight.bold)),
                    Text(
                      l10n.savedSmbFtpSftpNfsWebdav,
                      style: composeBody(fontSize: 12, color: scheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
              FilledButton.icon(
                key: const ValueKey('shares.add'),
                icon: const Icon(Icons.add),
                label: Text(l10n.add),
                onPressed: () => _edit(context, vm, add: true),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
          child: SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              key: const ValueKey('shares.scan.open'),
              icon: const Icon(Icons.radar, size: 18),
              label: Text(l10n.scanLanForShares, style: composeBody(fontSize: 12)),
              onPressed: () => _scan(context, vm),
            ),
          ),
        ),
        Expanded(
          // Kotlin's pull-to-refresh on this list checks every saved share.
          child: RefreshIndicator(
            key: const ValueKey('shares.refresh'),
            onRefresh: vm.testAll,
            child: vm.shares.isEmpty
                ? LayoutBuilder(
                    builder: (context, constraints) => SingleChildScrollView(
                      physics: const AlwaysScrollableScrollPhysics(),
                      child: SizedBox(
                        height: constraints.maxHeight,
                        child: Center(
                          child: Text(
                            l10n.noNetworkSharesSavedYet,
                            key: const ValueKey('shares.empty'),
                            style: composeBody(color: scheme.onSurfaceVariant),
                          ),
                        ),
                      ),
                    ),
                  )
                : ListView.separated(
                    key: const ValueKey('shares.list'),
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
                    itemCount: vm.shares.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 8),
                    itemBuilder: (context, index) {
                      final share = vm.shares[index];
                      return _ShareCard(
                        share: share,
                        checking: vm.isChecking(share.id),
                        authLabel: vm.authLabel(share),
                        onTest: () => vm.test(share),
                        onBrowse: () => context.read<SftpViewModel>().openShare(share),
                        onEdit: () => _edit(context, vm, share: share),
                        onDelete: () => _confirmDelete(context, vm, share),
                      );
                    },
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
    await showDialog<void>(
      context: context,
      builder: (_) =>
          ChangeNotifierProvider<SharesViewModel>.value(value: vm, child: const _ShareForm()),
    );
    vm.cancelEdit();
  }

  /// Kotlin's `NetworkShareScanDialog`. A hit that needs a path or an account (SMB, SFTP) closes it
  /// and opens the form; any other is saved as it stands, and closes it too.
  Future<void> _scan(BuildContext context, SharesViewModel vm) async {
    final network = context.read<NetworkViewModel?>();
    await vm.prepareScan();
    if (!context.mounted) return;
    final picked = await showDialog<ShareScanHit>(
      context: context,
      builder: (_) => MultiProvider(
        providers: [
          ChangeNotifierProvider<SharesViewModel>.value(value: vm),
          if (network != null) ChangeNotifierProvider<NetworkViewModel>.value(value: network),
        ],
        child: const _ScanDialog(),
      ),
    );
    if (picked != null && context.mounted) await _edit(context, vm, fromScan: picked);
  }

  Future<void> _confirmDelete(BuildContext context, SharesViewModel vm, NetworkShare share) async {
    final l10n = AppLocalizations.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        key: const ValueKey('shares.delete.dialog'),
        title: Text(l10n.delete3(share.name)),
        // The blast radius, stated: "delete" next to a file browser reads as destructive.
        content: Text(l10n.removesThisSavedShareProfileFiles),
        actions: [
          TextButton(
            key: const ValueKey('shares.delete.cancel'),
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(l10n.cancel),
          ),
          TextButton(
            key: const ValueKey('shares.delete.confirm'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(l10n.delete, style: const TextStyle(color: OmniColors.red)),
          ),
        ],
      ),
    );
    if (confirmed == true) await vm.delete(share);
  }
}

/// Kotlin's `NetworkShareScanDialog`: finds share services on the local network, so a NAS does not
/// have to be known before it can be saved. Pops with a hit to configure, or with nothing.
class _ScanDialog extends StatelessWidget {
  const _ScanDialog();

  static bool _needsForm(ShareScanHit hit) => hit.protocol == 'SMB' || hit.protocol == 'SFTP';

  Future<void> _pick(BuildContext context, SharesViewModel vm, ShareScanHit hit) async {
    if (_needsForm(hit)) {
      Navigator.of(context).pop(hit);
      return;
    }
    await vm.saveFromScan(hit);
    if (context.mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final vm = context.watch<SharesViewModel>();
    final network = context.watch<NetworkViewModel?>();
    final hostnames = {
      for (final host in network?.scanResults ?? const <ScannedHost>[])
        if ((host.hostname ?? '').isNotEmpty) host.address: host.hostname!,
    };
    final scheme = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context);
    final muted = composeBody(fontSize: 12, color: scheme.onSurfaceVariant);

    return AlertDialog(
      key: const ValueKey('shares.scan.dialog'),
      title: Text(l10n.lanShareScan),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: 8,
          children: [
            _Field(
              fieldKey: 'scanInput',
              label: l10n.subnetOrHost,
              hint: l10n.str1921681024Or,
              value: vm.scanInput,
              onChanged: (value) => vm.scanInput = value,
            ),
            FilledButton(
              key: const ValueKey('shares.scan.start'),
              onPressed: vm.scanning
                  ? null
                  : () => vm.scanForShares(vm.scanInput, lanTargets: network?.lanTargets),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: vm.scanning
                    ? [
                        const SizedBox.square(
                          dimension: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                        const SizedBox(width: 8),
                        Text(l10n.scanningShares),
                      ]
                    : [
                        const Icon(Icons.search, size: 18),
                        const SizedBox(width: 8),
                        Text(
                          vm.scanHits.isEmpty ? l10n.scanLanShares : l10n.rescanLanShares,
                          style: composeBody(fontSize: 12),
                        ),
                      ],
              ),
            ),
            if (vm.scanning)
              // Determinate: a sweep of 254 addresses takes long enough that a spinner alone reads
              // as a hang.
              LinearProgressIndicator(value: vm.scanProgress, minHeight: 2),
            // Protocol noise filter: drop WebDAV on networks where every printer answers on 80/443.
            Wrap(
              spacing: 6,
              children: [
                for (final protocol in allScanProtocols)
                  FilterChip(
                    key: ValueKey('shares.scan.protocol.$protocol'),
                    label: Text(protocol, style: composeBody(fontSize: 10)),
                    selected: vm.isScanProtocolEnabled(protocol),
                    onSelected: vm.scanning ? null : (_) => vm.toggleScanProtocol(protocol),
                  ),
              ],
            ),
            Text(l10n.probesSmb445Ftp21Sftp, style: muted.copyWith(fontSize: 11)),
            if (vm.scanStatus != null)
              Text(
                vm.scanStatus!,
                key: const ValueKey('shares.scan.status'),
                style: muted.copyWith(fontFamily: OmniFonts.mono),
              ),
            if (!vm.scanning && vm.scanHits.isEmpty)
              Text(l10n.noSharesYetRunAScan, key: const ValueKey('shares.scan.none'), style: muted),
            // Rows rather than a nested list: the dialog measures its content, which a lazy list
            // cannot report, and the content already scrolls.
            for (final hit in vm.scanHits)
              _ScanHitRow(
                hit: hit,
                hostLabel: hostnames[hit.address] ?? hit.address,
                action: _needsForm(hit) ? l10n.configure : l10n.save,
                onPressed: () => _pick(context, vm, hit),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          key: const ValueKey('shares.scan.close'),
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.close),
        ),
      ],
    );
  }
}

/// Kotlin's `NetworkShareScanHitRow`.
class _ScanHitRow extends StatelessWidget {
  const _ScanHitRow({
    required this.hit,
    required this.hostLabel,
    required this.action,
    required this.onPressed,
  });

  final ShareScanHit hit;

  /// The name the LAN sweep found for the address, or the address. Deliberately not routed through
  /// HostDisplay: this is a live result of a scan the user just ran, and the address is the result.
  final String hostLabel;
  final String action;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      key: ValueKey('shares.scan.hit.${hit.address}:${hit.port}'),
      children: [
        const Icon(Icons.lan, color: OmniColors.green),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '$hostLabel · ${hit.protocol}',
                style: const TextStyle(
                  fontFamily: OmniFonts.mono,
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                ),
              ),
              Text(
                '${hit.address}:${hit.port}',
                style: TextStyle(
                  fontFamily: OmniFonts.mono,
                  fontSize: 11,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
        TextButton(
          key: ValueKey('shares.scan.pick.${hit.address}:${hit.port}'),
          onPressed: onPressed,
          child: Text(action),
        ),
      ],
    );
  }
}

/// Kotlin's `NetworkShareCard`.
class _ShareCard extends StatelessWidget {
  const _ShareCard({
    required this.share,
    required this.checking,
    required this.authLabel,
    required this.onTest,
    required this.onBrowse,
    required this.onEdit,
    required this.onDelete,
  });

  final NetworkShare share;
  final bool checking;
  final String authLabel;
  final VoidCallback onTest;
  final VoidCallback onBrowse;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  /// Kotlin's `shareProtocolColor`.
  static Color accentFor(ShareProtocol protocol) => switch (protocol) {
    ShareProtocol.smb || ShareProtocol.custom => OmniColors.cyan,
    ShareProtocol.ftp => OmniColors.green,
    ShareProtocol.sftp => OmniColors.amber,
    ShareProtocol.nfs => OmniColors.purple,
    ShareProtocol.webdav => OmniColors.orange,
  };

  /// Kotlin's `shareAvailabilityUi`. "Unknown" is its own grey rather than borrowed from
  /// "Unavailable": never checked and checked-and-failed are different facts.
  static (String, Color) availability(String status, {required bool checking}) {
    if (checking) return ('Checking', OmniColors.amber);
    return switch (status.toLowerCase()) {
      'online' || 'available' || 'ok' => ('Available', OmniColors.green),
      'checking' || 'testing' => ('Checking', OmniColors.amber),
      'unreachable' || 'offline' || 'failed' || 'error' => ('Unavailable', _red),
      _ => ('Unknown', _grey),
    };
  }

  // Compose's `Color.Red` and `Color.Gray`, not the theme's red: Kotlin uses the raw constants here.
  static const _red = Color(0xFFFF0000);
  static const _grey = Color(0xFF888888);

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context);
    final protocol = ShareProtocol.fromId(share.protocol);
    final accent = accentFor(protocol);
    final browsable = shareIsBrowsable(protocol);
    final (statusLabel, statusColour) = availability(share.lastStatus, checking: checking);
    final shareName = share.sharePath.trim().isEmpty ? share.name : share.sharePath;
    final muted = composeBody(fontSize: 11, color: scheme.onSurfaceVariant);

    return OmniCard(
      key: ValueKey('shares.card.${share.id}'),
      leftAccent: accent,
      inset: const EdgeInsets.all(12),
      // Routed through HostDisplay: a share list is exactly the sort of screen that ends up in a
      // screenshot, and both the host line and the URI carry the address.
      child: ListenableBuilder(
        listenable: HostDisplay.instance,
        builder: (context, _) {
          final address = HostDisplay.instance.sensitive(share.address);
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: 6,
            children: [
              Row(
                children: [
                  Icon(Icons.folder_shared, color: accent),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Flexible(
                              child: Text(
                                share.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: composeBody(fontSize: 14, fontWeight: FontWeight.bold),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Container(
                              width: 9,
                              height: 9,
                              decoration: BoxDecoration(
                                color: statusColour,
                                shape: BoxShape.circle,
                              ),
                            ),
                            const SizedBox(width: 4),
                            Text(
                              statusLabel,
                              key: ValueKey('shares.card.${share.id}.status'),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: composeBody(fontSize: 11, color: statusColour),
                            ),
                          ],
                        ),
                        Text(
                          address,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: composeBody(fontSize: 12, color: scheme.onSurface),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    key: ValueKey('shares.card.${share.id}.browse'),
                    // Disabled, not hidden, and the reason is its description, as in Kotlin.
                    tooltip: browsable
                        ? l10n.browseFiles
                        : l10n.browsingNotSupportedFor(share.protocol),
                    onPressed: browsable ? onBrowse : null,
                    icon: Icon(
                      Icons.folder_open,
                      color: browsable ? accent : scheme.onSurfaceVariant.withValues(alpha: 0.4),
                    ),
                  ),
                  IconButton(
                    key: ValueKey('shares.card.${share.id}.test'),
                    tooltip: l10n.testShare,
                    onPressed: onTest,
                    icon: const Icon(Icons.network_ping),
                  ),
                  IconButton(
                    key: ValueKey('shares.card.${share.id}.edit'),
                    tooltip: l10n.editShare,
                    onPressed: onEdit,
                    icon: const Icon(Icons.edit),
                  ),
                  IconButton(
                    key: ValueKey('shares.card.${share.id}.delete'),
                    tooltip: l10n.deleteShare,
                    onPressed: onDelete,
                    icon: const Icon(Icons.delete, color: _red),
                  ),
                ],
              ),
              Text(
                '$shareName · ${share.protocol} · $authLabel',
                key: ValueKey('shares.card.${share.id}.detail'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: muted,
              ),
              Text(
                shareUri(share, maskedAddress: address),
                key: ValueKey('shares.card.${share.id}.uri'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: muted.copyWith(fontFamily: OmniFonts.mono),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// Kotlin's `NetworkShareDialog` (`ui/SftpScreen.kt`).
class _ShareForm extends StatelessWidget {
  const _ShareForm();

  @override
  Widget build(BuildContext context) {
    final vm = context.watch<SharesViewModel>();
    final draft = vm.draft;
    if (draft == null) return const SizedBox.shrink();

    final l10n = AppLocalizations.of(context);
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    final error = draft.validationError;
    final sftp = draft.protocol == ShareProtocol.sftp;
    final portInvalid = draft.protocol != ShareProtocol.custom && portError(draft.port) != null;

    void toggleHttps() => vm.updateDraft((d) => d.copyWith(useHttps: !d.useHttps));
    // Going anonymous drops the profile and typed credentials, as Kotlin does.
    void toggleAnonymous() => vm.updateDraft(
      (d) => d.anonymous
          ? d.copyWith(anonymous: false)
          : d.copyWith(anonymous: true, clearAuthProfile: true, username: '', password: ''),
    );

    Widget warning(String key, String text) => SizedBox(
      width: double.infinity,
      child: Text(
        text,
        key: ValueKey('shares.form.warning.$key'),
        style: composeDialogBody(fontSize: 12, color: OmniColors.amber),
      ),
    );

    return AlertDialog(
      key: const ValueKey('shares.form.dialog'),
      title: Text(draft.id == 0 ? l10n.addNetworkShare : l10n.editNetworkShare),
      content: SizedBox(
        width: double.maxFinite,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            spacing: 10,
            children: [
              _Field(
                fieldKey: 'name',
                label: l10n.customName,
                value: draft.name,
                onChanged: (v) => vm.updateDraft((d) => d.copyWith(name: v)),
              ),
              DropdownButtonFormField<ShareProtocol>(
                key: const ValueKey('shares.form.protocol'),
                initialValue: draft.protocol,
                decoration: InputDecoration(
                  labelText: l10n.protocol,
                  border: const OutlineInputBorder(),
                  isDense: true,
                ),
                items: [
                  for (final protocol in ShareProtocol.values)
                    DropdownMenuItem(
                      key: ValueKey('shares.form.protocol.${protocol.id}'),
                      value: protocol,
                      child: Text(protocol.id),
                    ),
                ],
                onChanged: (protocol) {
                  if (protocol != null) vm.updateDraft((d) => d.withProtocol(protocol));
                },
              ),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                spacing: 8,
                children: [
                  Expanded(
                    child: _Field(
                      fieldKey: 'address',
                      label: l10n.address,
                      value: draft.address,
                      onChanged: (v) => vm.updateDraft((d) => d.copyWith(address: v)),
                    ),
                  ),
                  SizedBox(
                    width: 96,
                    child: _Field(
                      // Keyed by protocol so a protocol change shows the port it moved to.
                      key: ValueKey('port-${draft.protocol.id}'),
                      fieldKey: 'port',
                      label: l10n.port,
                      value: draft.port,
                      isError: portInvalid,
                      digitsOnly: 5,
                      keyboardType: TextInputType.number,
                      onChanged: (v) => vm.updateDraft((d) => d.copyWith(port: v)),
                    ),
                  ),
                ],
              ),
              _Field(
                fieldKey: 'sharePath',
                label: l10n.sharePath,
                hint: l10n.sharedfolderOrExportsMedia,
                value: draft.sharePath,
                onChanged: (v) => vm.updateDraft((d) => d.copyWith(sharePath: v)),
              ),
              if (draft.protocol == ShareProtocol.webdav) ...[
                // Explicit rather than inferred from the port: Basic auth over plain HTTP on a
                // nonstandard TLS port (Synology's 5006, say) would send the password unseen.
                InkWell(
                  key: const ValueKey('shares.form.useHttps'),
                  borderRadius: BorderRadius.circular(8),
                  onTap: toggleHttps,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(l10n.useHttps, style: composeDialogBody()),
                              Text(
                                l10n.useHttpsNotInferredFromPort,
                                style: composeDialogBody(fontSize: 11, color: muted),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 8),
                        // Live, not null: a Flutter switch without a callback paints disabled,
                        // where Compose's `onCheckedChange = null` only hands the tap to the row.
                        Switch(value: draft.useHttps, onChanged: (_) => toggleHttps()),
                      ],
                    ),
                  ),
                ),
                if (draft.warnsWebDavCleartext)
                  warning('webdav', l10n.webdavWithoutHttpsSendsPassword),
              ],
              InkWell(
                key: const ValueKey('shares.form.anonymous'),
                borderRadius: BorderRadius.circular(8),
                // SSH has no anonymous mode, so it is not offered for SFTP at all.
                onTap: sftp ? null : toggleAnonymous,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    children: [
                      Checkbox(
                        value: draft.anonymous,
                        onChanged: sftp ? null : (_) => toggleAnonymous(),
                      ),
                      const SizedBox(width: 6),
                      Text(l10n.anonymousGuestLogin, style: composeDialogBody()),
                    ],
                  ),
                ),
              ),
              if (!draft.anonymous) ...[
                if (draft.warnsFtpCleartext) warning('ftp', l10n.ftpSendsUsernamesAndPasswordsIn),
                Text(l10n.credentialProfile, style: composeDialogBody(fontSize: 12, color: muted)),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    spacing: 8,
                    children: [
                      FilterChip(
                        key: const ValueKey('shares.form.profile.new'),
                        selected: draft.authProfileId == null,
                        label: Text(l10n.newProfile),
                        onSelected: (_) =>
                            vm.updateDraft((d) => d.copyWith(clearAuthProfile: true)),
                      ),
                      for (final profile in vm.profiles)
                        FilterChip(
                          key: ValueKey('shares.form.profile.${profile.id}'),
                          selected: draft.authProfileId == profile.id,
                          label: Text(
                            profile.profileName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          onSelected: (_) =>
                              vm.updateDraft((d) => d.copyWith(authProfileId: profile.id)),
                        ),
                    ],
                  ),
                ),
                if (draft.authProfileId == null) ...[
                  Text(
                    l10n.savingWillCreateAReusableCredential,
                    style: composeDialogBody(fontSize: 11, color: muted),
                  ),
                  _Field(
                    fieldKey: 'workgroup',
                    label: l10n.workgroupDomain,
                    value: draft.workgroup,
                    onChanged: (v) => vm.updateDraft((d) => d.copyWith(workgroup: v)),
                  ),
                  _Field(
                    fieldKey: 'username',
                    label: l10n.username,
                    value: draft.username,
                    onChanged: (v) => vm.updateDraft((d) => d.copyWith(username: v)),
                  ),
                  OmniPasswordField(
                    fieldKey: const ValueKey('shares.form.password'),
                    label: l10n.password,
                    initialValue: draft.password,
                    onChanged: (v) => vm.updateDraft((d) => d.copyWith(password: v)),
                  ),
                ],
              ],
              _Field(
                fieldKey: 'notes',
                label: l10n.notes,
                value: draft.notes,
                minLines: 2,
                onChanged: (v) => vm.updateDraft((d) => d.copyWith(notes: v)),
              ),
              if (vm.error != null)
                Text(
                  vm.error!,
                  key: const ValueKey('shares.form.error'),
                  style: composeDialogBody(fontSize: 12, color: OmniColors.red),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          key: const ValueKey('shares.form.cancel'),
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.cancel),
        ),
        // Disabled while the draft is invalid, as in Kotlin.
        FilledButton(
          key: const ValueKey('shares.form.save'),
          onPressed: error == null
              ? () async {
                  final saved = await vm.saveDraft();
                  if (saved && context.mounted) Navigator.of(context).pop();
                }
              : null,
          child: Text(l10n.save),
        ),
      ],
    );
  }
}

/// A labelled outlined text field (Kotlin's `OutlinedTextField`).
class _Field extends StatefulWidget {
  const _Field({
    super.key,
    required this.fieldKey,
    required this.label,
    required this.value,
    required this.onChanged,
    this.hint,
    this.isError = false,
    this.minLines,
    this.digitsOnly,
    this.keyboardType,
  });

  final String fieldKey;
  final String label;
  final String value;
  final ValueChanged<String> onChanged;
  final String? hint;
  final bool isError;
  final int? minLines;

  /// Kotlin's port field keeps digits only, at most this many.
  final int? digitsOnly;
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
  Widget build(BuildContext context) {
    final error = Theme.of(context).colorScheme.error;
    return TextField(
      key: ValueKey('shares.form.${widget.fieldKey}'),
      controller: _controller,
      autocorrect: false,
      keyboardType: widget.keyboardType,
      minLines: widget.minLines,
      maxLines: widget.minLines == null ? 1 : null,
      inputFormatters: widget.digitsOnly == null
          ? null
          : [
              FilteringTextInputFormatter.digitsOnly,
              LengthLimitingTextInputFormatter(widget.digitsOnly),
            ],
      onChanged: widget.onChanged,
      decoration: InputDecoration(
        labelText: widget.label,
        hintText: widget.hint,
        isDense: true,
        border: const OutlineInputBorder(),
        enabledBorder: widget.isError
            ? OutlineInputBorder(borderSide: BorderSide(color: error))
            : null,
        focusedBorder: widget.isError
            ? OutlineInputBorder(borderSide: BorderSide(color: error, width: 2))
            : null,
        labelStyle: widget.isError ? TextStyle(color: error) : null,
      ),
    );
  }
}
