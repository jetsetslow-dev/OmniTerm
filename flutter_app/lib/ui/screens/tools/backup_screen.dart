import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../../domain/backup_selection.dart';
import '../../../domain/host_display.dart';
import '../../../platform/backup_file_store.dart';
import '../../../platform/distribution.dart';
import '../../../platform/license_controller.dart';
import '../../navigation.dart';
import '../../theme/colors.dart';
import '../../theme/typography.dart';
import '../../view_model/backup_view_model.dart';
import '../../view_model/servers_view_model.dart';
import '../../widgets/omni_components.dart';
import '../../widgets/omni_confirm.dart';
import '../../widgets/popup_scroll_behavior.dart';

/// Kotlin's section labels (`BackupSelectionList` in `ui/ToolsScreen.kt`). A trailing `*` marks a
/// section that forces an encrypted backup; the legend under the list explains it once.
const backupSectionLabels = <BackupSection, String>{
  BackupSection.servers: 'Servers *',
  BackupSection.sshKeys: 'SSH keys *',
  BackupSection.credentialProfiles: 'Credential profiles *',
  BackupSection.scripts: 'Scripts *',
  BackupSection.alertRules: 'Alert rules *',
  BackupSection.activeAlerts: 'Active alerts',
  BackupSection.alertHistory: 'Alert history *',
  BackupSection.wolTargets: 'Wake on LAN *',
  BackupSection.networkShares: 'Network shares *',
  BackupSection.portForwards: 'SSH tunnels *',
  BackupSection.settings: 'Settings & customizations *',
  BackupSection.crashLogs: 'Crash logs *',
};

/// The Backup tool, a port of `BackupToolView` in `ui/ToolsScreen.kt`: one card with Backup and
/// Restore, and the section, passphrase and restore choices in dialogs.
///
/// The view model owns the *text*; where it lands is the platform's business, handled through an
/// injected [BackupFileStore] so the flow can be exercised without a system file dialog.
class BackupScreen extends StatefulWidget {
  const BackupScreen({super.key, this.fileStore = const BackupFileStore()});

  final BackupFileStore fileStore;

  @override
  State<BackupScreen> createState() => _BackupScreenState();
}

class _BackupScreenState extends State<BackupScreen> {
  final _scrollController = ScrollController();
  bool _exportPending = false;
  bool _importPending = false;

  /// True from the end of the dialogs until the export itself starts (notification permission),
  /// so the work already approved shows progress the whole way, as Kotlin's "Exporting…" does.
  bool _preparing = false;

  @override
  void initState() {
    super.initState();
    // Deferred: the read notifies listeners, and doing that during build throws.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final vm = context.read<BackupViewModel>();
      vm.loadLastExportTime();
      vm.loadSelection();
    });
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _revealFeedback() {
    if (mounted && _scrollController.hasClients) _scrollController.jumpTo(0);
  }

  @override
  Widget build(BuildContext context) {
    final vm = context.watch<BackupViewModel>();
    final scheme = Theme.of(context).colorScheme;
    final muted = composed(TextStyle(fontSize: 11, color: scheme.onSurfaceVariant));
    final message = vm.error ?? vm.status;
    final lastBackup = vm.lastExportTimeLoading
        ? 'Last backup: …'
        : vm.lastExportTime == null
        ? (vm.lastExportTimeError != null ? 'Last backup: Unknown' : 'Last backup: Never')
        : 'Last backup: ${DateFormat.yMMMd().add_jm().format(vm.lastExportTime!)}';
    // Reading or decrypting a file gets Kotlin's progress dialog, whoever started it; exporting
    // and restoring show the inline row under the buttons.
    final inspecting =
        vm.busy && (vm.busyMessage == 'Decrypting backup…' || vm.busyMessage == 'Reading backup…');
    final restoring = vm.busy && vm.busyMessage == 'Restoring backup…';

    return ToolScaffold(
      title: 'App backup',
      keyPrefix: 'backup',
      onBack: () => context.read<NavigationController>().navigateTo(Screen.tools),
      child: Stack(
        children: [
          ScrollConfiguration(
            behavior: const PopupScrollBehavior(popupsOnly: false),
            child: SingleChildScrollView(
              key: const ValueKey('backup.list'),
              controller: _scrollController,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: OmniCard(
                leftAccent: OmniColors.cyan,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'OmniTerm app backup',
                        style: composed(TextStyle(fontWeight: FontWeight.bold)),
                      ),
                      Text(
                        "Exports OmniTerm's own configuration — saved hosts, keys, scripts and "
                        'settings. It does NOT back up any files or data on your servers.',
                        style: muted,
                      ),
                      Text(lastBackup, key: const ValueKey('backup.lastExport'), style: muted),
                      if (vm.lastExportTimeError != null)
                        TextButton(
                          key: const ValueKey('backup.lastExport.retry'),
                          onPressed: vm.loadLastExportTime,
                          child: const Text('Retry checking backup time'),
                        ),
                      const SizedBox(height: 12),
                      Text(
                        'Tap Backup to choose export sections. Restore shows available sections '
                        'after the selected file is read.',
                        style: muted,
                      ),
                      const SizedBox(height: 12),
                      _SelectionFeedback(vm: vm),
                      Row(
                        children: [
                          Expanded(
                            child: FilledButton.icon(
                              key: const ValueKey('backup.export'),
                              onPressed: vm.busy || _exportPending ? null : () => _export(vm),
                              icon: const Icon(Icons.cloud_upload, semanticLabel: 'Backup'),
                              label: const Text('Backup', style: TextStyle(fontSize: 12)),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: FilledButton.icon(
                              key: const ValueKey('backup.import'),
                              style: FilledButton.styleFrom(backgroundColor: scheme.secondary),
                              onPressed: vm.busy || _importPending ? null : () => _import(vm),
                              icon: const Icon(
                                Icons.cloud_download,
                                semanticLabel: 'Restore Backup',
                              ),
                              label: const Text('Restore', style: TextStyle(fontSize: 12)),
                            ),
                          ),
                        ],
                      ),
                      // Export and restore run for seconds on a large backup, after the picker
                      // has closed, so the in-flight state shows here where the result lands.
                      if ((vm.busy || _preparing) && !inspecting)
                        Padding(
                          key: const ValueKey('backup.progress'),
                          padding: const EdgeInsets.only(top: 8),
                          child: Row(
                            children: [
                              const SizedBox.square(
                                dimension: 14,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              ),
                              const SizedBox(width: 8),
                              Text(
                                restoring ? 'Restoring…' : 'Exporting…',
                                style: composed(
                                  TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                                ),
                              ),
                            ],
                          ),
                        ),
                      if (message != null && message.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Text(
                            message,
                            key: const ValueKey('backup.message'),
                            style: composed(
                              TextStyle(
                                fontSize: 12,
                                color: vm.error != null
                                    ? OmniColors.red
                                    : vm.statusIsSuccess
                                    ? OmniColors.green
                                    : OmniColors.amber,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          // Kotlin's `BackupReadProgressDialog`: reading or decrypting a picked file.
          if (inspecting) ...[
            const Positioned.fill(child: ModalBarrier(dismissible: false, color: Colors.black38)),
            Center(
              child: AlertDialog(
                key: const ValueKey('backup.readProgress'),
                scrollable: true,
                title: Text(vm.busyMessage),
                content: const Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CircularProgressIndicator(),
                    SizedBox(height: 16),
                    Text('This may take a little while. Please wait.'),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _export(BackupViewModel vm) async {
    if (_exportPending || vm.busy) return;
    setState(() => _exportPending = true);
    try {
      await _performExport(vm);
    } finally {
      if (mounted) setState(() => _exportPending = false);
      _revealFeedback();
    }
  }

  Future<void> _performExport(BackupViewModel vm) async {
    const cancelled = 'Backup cancelled. Nothing was written.';
    final proceed = await showDialog<bool>(
      context: context,
      builder: (_) => ChangeNotifierProvider<BackupViewModel>.value(
        value: vm,
        child: const _BackupSectionsDialog(),
      ),
    );
    if (proceed != true) return vm.reportCancelled(cancelled);
    final selection = vm.selection;
    var passphrase = '';
    if (selection.hasSensitiveData) {
      if (!mounted) return;
      final entered = await showDialog<String>(
        context: context,
        builder: (_) => const _PassphraseDialog(
          title: 'Encrypt Backup',
          note:
              "Sensitive backup sections require encryption. Choose a passphrase you'll need "
              'for restore.',
          label: 'Passphrase (min ${BackupViewModel.passphraseMinLength} chars)',
          confirmLabel: 'Choose location',
          minLength: BackupViewModel.passphraseMinLength,
        ),
      );
      if (entered == null) return vm.reportCancelled(cancelled);
      passphrase = entered;
    }
    // Sequenced before the export, because the export starts a foreground operation whose
    // permission request would otherwise land on top of the file picker opened moments later.
    if (mounted) setState(() => _preparing = true);
    final String? contents;
    try {
      await vm.operationNotifications?.ensureNotificationPermission();
      contents = await vm.exportBackup(passphrase, selection: selection);
    } finally {
      if (mounted) setState(() => _preparing = false);
    }
    if (contents == null) return;
    final result = await widget.fileStore.save(vm.suggestedFileName(), contents);
    // Not gated on `mounted`: saving hands off to the system picker, so this screen is routinely
    // unmounted when the file is written, and the app-scoped view model must still record it.
    switch (result.outcome) {
      case BackupSaveOutcome.saved:
        vm.reportSaved(result.location, encrypted: passphrase.isNotEmpty);
      case BackupSaveOutcome.cancelled:
        vm.reportSaveCancelled();
      case BackupSaveOutcome.failed:
        vm.reportSaveFailed(result.error);
    }
  }

  Future<void> _import(BackupViewModel vm) async {
    if (_importPending || vm.busy) return;
    setState(() => _importPending = true);
    try {
      await _performImport(vm);
    } finally {
      if (mounted) setState(() => _importPending = false);
      _revealFeedback();
    }
  }

  Future<void> _performImport(BackupViewModel vm) async {
    const cancelled = 'Restore cancelled. Nothing was changed.';
    String? contents;
    try {
      contents = await widget.fileStore.open();
    } on BackupReadException catch (e) {
      return vm.reportSaveFailed(e.message);
    }
    if (contents == null) return vm.reportCancelled(cancelled);
    if (contents.trim().isEmpty) {
      return vm.reportSaveFailed(
        'That file is empty, so there is nothing to restore. Choose the backup file you exported — '
        'it ends in .json and is usually several kilobytes.',
      );
    }
    if (!mounted) return;
    var passphrase = '';
    if (BackupViewModel.looksEncrypted(contents)) {
      final entered = await showDialog<String>(
        context: context,
        builder: (_) => const _PassphraseDialog(
          title: 'Encrypted Backup',
          note: 'Enter the password to decrypt the backup.',
          label: 'Password',
          confirmLabel: 'Restore',
        ),
      );
      if (entered == null) return vm.reportCancelled(cancelled);
      passphrase = entered;
    }
    final inspection = await vm.inspectBackup(contents, passphrase);
    if (inspection == null || !mounted) return;
    final license = context.read<LicenseController?>();
    final hasHostLimit = isPlayStoreDistribution && !(license?.state.value.unlocked ?? true);
    final choice = await showDialog<_RestoreChoice>(
      context: context,
      builder: (_) => _RestoreSelectionDialog(inspection: inspection, hasHostLimit: hasHostLimit),
    );
    if (choice == null || !mounted) return vm.reportCancelled(cancelled);
    final confirmed = await showOmniConfirm(
      context,
      title: 'Restore selected data?',
      message:
          'Restoring selected sections will add matching backup contents into OmniTerm. This '
          'cannot be undone.',
      confirmLabel: 'Restore',
      keyPrefix: 'backup.restore.confirmDialog',
    );
    if (!confirmed) return vm.reportCancelled(cancelled);
    await vm.importBackup(
      inspection.plainJson,
      '',
      selection: choice.selection,
      selectedServerIds: choice.hostIds,
    );
  }
}

/// Kotlin's `BackupSelectionFeedback`.
class _SelectionFeedback extends StatelessWidget {
  const _SelectionFeedback({required this.vm, this.keyPrefix = 'backup.selection'});

  final BackupViewModel vm;

  /// Kotlin shows this feedback on the card and inside the sections dialog; distinct keys keep
  /// each copy addressable.
  final String keyPrefix;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      if (vm.selectionSaving) ...[
        const LinearProgressIndicator(),
        Text('Remembering backup selection…', style: composed(TextStyle(fontSize: 11))),
      ],
      if (vm.selectionSaveError != null) ...[
        Text(
          vm.selectionSaveError!,
          key: ValueKey('$keyPrefix.error'),
          style: composed(TextStyle(fontSize: 11, color: OmniColors.red)),
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton(
            key: ValueKey('$keyPrefix.retry'),
            onPressed: vm.retrySelectionSave,
            child: const Text('Retry remembering selection'),
          ),
        ),
      ],
    ],
  );
}

/// Kotlin's "Backup sections" dialog. Changes persist as the remembered selection immediately,
/// as `setExportSelection` does.
class _BackupSectionsDialog extends StatelessWidget {
  const _BackupSectionsDialog();

  @override
  Widget build(BuildContext context) {
    final vm = context.watch<BackupViewModel>();
    final scheme = Theme.of(context).colorScheme;
    return AlertDialog(
      key: const ValueKey('backup.sections.dialog'),
      title: const Text('Backup sections'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 420),
        child: ScrollConfiguration(
          behavior: const PopupScrollBehavior(),
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _SelectionFeedback(vm: vm, keyPrefix: 'backup.sections.selection'),
                BackupSelectionList(
                  title: 'Choose what to include',
                  selection: vm.selection,
                  onChanged: (section, enabled) => vm.toggleSection(section, enabled: enabled),
                  keyPrefix: 'backup.section',
                ),
                const SizedBox(height: 8),
                Text(
                  vm.selection.hasSensitiveData
                      ? 'Sensitive sections selected: backup will be encrypted.'
                      : 'No sensitive sections selected: backup will be plain JSON.',
                  key: const ValueKey('backup.sensitiveNote'),
                  style: composed(
                    TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
                    lineHeight: 20,
                    tracking: 0.25,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          key: const ValueKey('backup.sections.cancel'),
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        TextButton(
          key: const ValueKey('backup.sections.continue'),
          onPressed: vm.selection.isEmpty ? null : () => Navigator.of(context).pop(true),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (vm.selectionSaving) ...[
                const SizedBox.square(
                  dimension: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: 6),
              ],
              const Text('Continue'),
            ],
          ),
        ),
      ],
    );
  }
}

/// Kotlin's `BackupSelectionList`: one checkbox row per section, a count after each label when a
/// file's contents are known, and the two legend lines.
class BackupSelectionList extends StatelessWidget {
  const BackupSelectionList({
    super.key,
    required this.title,
    required this.selection,
    required this.onChanged,
    required this.keyPrefix,
    this.counts,
  });

  final String title;
  final BackupSelection selection;
  final Map<BackupSection, int>? counts;
  final void Function(BackupSection section, bool enabled) onChanged;
  final String keyPrefix;

  bool _enabled(BackupSection section) {
    final c = counts;
    if (c == null) return true;
    int n(BackupSection s) => c[s] ?? 0;
    return switch (section) {
      BackupSection.activeAlerts =>
        n(BackupSection.activeAlerts) > 0 &&
            n(BackupSection.alertRules) > 0 &&
            n(BackupSection.servers) > 0,
      BackupSection.portForwards =>
        n(BackupSection.portForwards) > 0 && n(BackupSection.servers) > 0,
      _ => n(section) > 0,
    };
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final legend = composed(
      TextStyle(fontSize: 10, color: scheme.onSurfaceVariant),
      lineHeight: 20,
      tracking: 0.25,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: composed(
            TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
            lineHeight: 20,
            tracking: 0.25,
          ),
        ),
        for (final section in BackupSection.values)
          Row(
            children: [
              Checkbox(
                key: ValueKey('$keyPrefix.${section.name}'),
                value: selection.contains(section) && _enabled(section),
                onChanged: _enabled(section) ? (value) => onChanged(section, value ?? false) : null,
              ),
              Flexible(
                child: Text(
                  counts == null
                      ? backupSectionLabels[section]!
                      : '${backupSectionLabels[section]} (${counts![section] ?? 0})',
                  style: composed(
                    TextStyle(
                      fontSize: 12,
                      color: _enabled(section) ? scheme.onSurface : scheme.onSurfaceVariant,
                    ),
                    lineHeight: 20,
                    tracking: 0.25,
                  ),
                ),
              ),
            ],
          ),
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text('* Sensitive — selecting forces an encrypted backup.', style: legend),
        ),
        Text(
          'Alert rules and history include Servers. Active alerts also include Alert rules. SSH '
          'tunnels include Servers.',
          style: legend,
        ),
      ],
    );
  }
}

/// Kotlin's passphrase dialogs ("Encrypt Backup" for export, "Encrypted Backup" for restore).
class _PassphraseDialog extends StatefulWidget {
  const _PassphraseDialog({
    required this.title,
    required this.note,
    required this.label,
    required this.confirmLabel,
    this.minLength = 1,
  });

  final String title;
  final String note;
  final String label;
  final String confirmLabel;
  final int minLength;

  @override
  State<_PassphraseDialog> createState() => _PassphraseDialogState();
}

class _PassphraseDialogState extends State<_PassphraseDialog> {
  String _value = '';

  @override
  Widget build(BuildContext context) => AlertDialog(
    key: const ValueKey('backup.passphrase.dialog'),
    scrollable: true,
    title: Text(widget.title),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(widget.note, style: composed(TextStyle(fontSize: 12), lineHeight: 20, tracking: 0.25)),
        const SizedBox(height: 8),
        OmniPasswordField(
          fieldKey: const ValueKey('backup.passphrase.field'),
          label: widget.label,
          autofocus: true,
          onChanged: (value) => setState(() => _value = value),
        ),
      ],
    ),
    actions: [
      TextButton(
        key: const ValueKey('backup.passphrase.cancel'),
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('Cancel'),
      ),
      TextButton(
        key: const ValueKey('backup.passphrase.confirm'),
        onPressed: _value.length >= widget.minLength
            ? () => Navigator.of(context).pop(_value)
            : null,
        child: Text(widget.confirmLabel),
      ),
    ],
  );
}

@immutable
class _RestoreChoice {
  const _RestoreChoice(this.selection, this.hostIds);

  final BackupSelection selection;
  final Set<int> hostIds;
}

/// Kotlin's `backupSelectionFromContents`: everything present, firing alerts only with their hosts
/// and rules, tunnels only with their hosts, and crash logs never by default.
BackupSelection kotlinRestoreDefault(Map<BackupSection, int> counts) {
  bool has(BackupSection s) => (counts[s] ?? 0) > 0;
  final hasServers = has(BackupSection.servers);
  final hasRules = has(BackupSection.alertRules);
  return BackupSelection({
    for (final section in BackupSection.values)
      if (switch (section) {
        BackupSection.activeAlerts => has(section) && hasServers && hasRules,
        BackupSection.portForwards => has(section) && hasServers,
        BackupSection.crashLogs => false,
        _ => has(section),
      })
        section,
  }).withReferentialClosure();
}

/// Kotlin's "Restore backup" dialog: available sections with counts, then the hosts to restore.
class _RestoreSelectionDialog extends StatefulWidget {
  const _RestoreSelectionDialog({required this.inspection, required this.hasHostLimit});

  final BackupInspection inspection;

  /// True on a free Play build, where saved hosts are capped.
  final bool hasHostLimit;

  @override
  State<_RestoreSelectionDialog> createState() => _RestoreSelectionDialogState();
}

class _RestoreSelectionDialogState extends State<_RestoreSelectionDialog> {
  late BackupSelection _selection = kotlinRestoreDefault(widget.inspection.counts);
  late final int? _hostCap = restoreHostCap(
    hasHostLimit: widget.hasHostLimit,
    hostLimit: ServersViewModel.freePlayStoreLimit,
  );
  late final Set<int> _hostIds = defaultRestoreHostIds(
    widget.inspection.hosts.map((host) => host.oldId),
    cap: _hostCap,
  );

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final hosts = widget.inspection.hosts;
    final showHosts = hosts.isNotEmpty && _selection.contains(BackupSection.servers);
    final cap = _hostCap;
    return AlertDialog(
      key: const ValueKey('backup.restore.selectionDialog'),
      title: const Text('Restore backup'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 420),
        child: ScrollConfiguration(
          behavior: const PopupScrollBehavior(),
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Choose what to restore from this backup.',
                  style: composed(TextStyle(fontSize: 12), lineHeight: 20, tracking: 0.25),
                ),
                const SizedBox(height: 8),
                BackupSelectionList(
                  title: 'Available sections',
                  selection: _selection,
                  counts: widget.inspection.counts,
                  keyPrefix: 'backup.restore.section',
                  onChanged: (section, enabled) => setState(() {
                    _selection = _selection.toggled(section, enabled: enabled);
                  }),
                ),
                if (showHosts) ...[
                  const Divider(),
                  Text(
                    'Hosts to restore',
                    style: composed(
                      TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
                      lineHeight: 20,
                      tracking: 0.25,
                    ),
                  ),
                  if (cap != null)
                    Text(
                      'Free Play Store restore is limited to $cap host${cap == 1 ? '' : 's'}.',
                      key: const ValueKey('backup.restore.hostCap'),
                      style: composed(
                        TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
                        lineHeight: 20,
                        tracking: 0.25,
                      ),
                    ),
                  for (final host in hosts)
                    Row(
                      children: [
                        Checkbox(
                          key: ValueKey('backup.restore.host.${host.oldId}'),
                          value: _hostIds.contains(host.oldId),
                          onChanged:
                              _hostIds.contains(host.oldId) || cap == null || _hostIds.length < cap
                              ? (next) => setState(() {
                                  next == true
                                      ? _hostIds.add(host.oldId)
                                      : _hostIds.remove(host.oldId);
                                })
                              : null,
                        ),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                host.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: composed(
                                  TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                                  lineHeight: 20,
                                  tracking: 0.25,
                                ),
                              ),
                              // The name is already above, so the address is masked outright.
                              Text(
                                '${HostDisplay.instance.sensitive(host.host)}:${host.port}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: composed(
                                  TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
                                  lineHeight: 20,
                                  tracking: 0.25,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                ],
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          key: const ValueKey('backup.restore.cancel'),
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        TextButton(
          key: const ValueKey('backup.restore.continue'),
          onPressed: _selection.isEmpty
              ? null
              : () => Navigator.pop(
                  context,
                  _RestoreChoice(
                    _selection,
                    _selection.contains(BackupSection.servers) ? _hostIds : const {},
                  ),
                ),
          child: const Text('Restore'),
        ),
      ],
    );
  }
}
