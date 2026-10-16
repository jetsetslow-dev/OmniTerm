import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../../domain/backup_selection.dart';
import '../../../platform/backup_file_store.dart';
import '../../../platform/distribution.dart';
import '../../../platform/license_controller.dart';
import '../../view_model/servers_view_model.dart';
import '../../theme/colors.dart';
import '../../view_model/backup_view_model.dart';
import '../../widgets/omni_components.dart';

/// The Backup tool, ported from `BackupToolView` in `ui/ToolsScreen.kt`.
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
  BackupViewModel? _feedbackModel;
  String? _lastSelectionSaveError;
  bool _exportPending = false;
  String? _exportProgress;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final model = context.read<BackupViewModel>();
    if (identical(model, _feedbackModel)) return;
    _feedbackModel?.removeListener(_selectionFeedbackChanged);
    _feedbackModel = model;
    _lastSelectionSaveError = null;
    model.addListener(_selectionFeedbackChanged);
    _selectionFeedbackChanged();
  }

  void _selectionFeedbackChanged() {
    final error = _feedbackModel?.selectionSaveError;
    if (error != null && error != _lastSelectionSaveError) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _revealFeedback());
    }
    _lastSelectionSaveError = error;
  }

  @override
  void dispose() {
    _feedbackModel?.removeListener(_selectionFeedbackChanged);
    _scrollController.dispose();
    super.dispose();
  }

  void _revealFeedback() {
    if (mounted && _scrollController.hasClients) _scrollController.jumpTo(0);
  }

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
  Widget build(BuildContext context) {
    final vm = context.watch<BackupViewModel>();
    final scheme = Theme.of(context).colorScheme;
    final working = vm.busy || _exportPending;
    final showProgress = vm.busy || (_exportPending && _exportProgress != null);
    final progressMessage = vm.busy ? vm.busyMessage : _exportProgress ?? 'Preparing backup…';

    return Stack(
      children: [
        ListView(
          controller: _scrollController,
          key: const ValueKey('backup.list'),
          padding: const EdgeInsets.all(12),
          children: [
            if (vm.status != null || vm.error != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: OmniCard(
                  key: const ValueKey('backup.message'),
                  // Green means "this worked". A cancelled save did not, so it gets the neutral
                  // accent rather than borrowing the colour the user reads as success.
                  leftAccent: vm.error != null
                      ? OmniColors.red
                      : vm.statusIsSuccess
                      ? OmniColors.green
                      : OmniColors.amber,
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          vm.error ?? vm.status!,
                          style: TextStyle(
                            fontSize: 12,
                            color: vm.error != null ? OmniColors.red : null,
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip: 'Dismiss',
                        key: const ValueKey('backup.message.dismiss'),
                        icon: const Icon(Icons.close, size: 16),
                        onPressed: vm.dismissMessages,
                      ),
                    ],
                  ),
                ),
              ),
            const SectionHeader(title: 'What to include'),
            if (vm.selectionSaving) ...[
              const LinearProgressIndicator(),
              const Text('Remembering backup selection…', style: TextStyle(fontSize: 11)),
            ],
            if (vm.selectionSaveError != null) ...[
              Text(
                vm.selectionSaveError!,
                key: const ValueKey('backup.selection.error'),
                style: const TextStyle(fontSize: 11, color: OmniColors.red),
              ),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  key: const ValueKey('backup.selection.retry'),
                  onPressed: vm.retrySelectionSave,
                  child: const Text('Retry remembering selection'),
                ),
              ),
            ],
            Row(
              children: [
                TextButton(
                  key: const ValueKey('backup.selectAll'),
                  onPressed: working ? null : vm.selectAll,
                  child: const Text('All', style: TextStyle(fontSize: 12)),
                ),
                TextButton(
                  key: const ValueKey('backup.selectNone'),
                  onPressed: working ? null : vm.selectNone,
                  child: const Text('None', style: TextStyle(fontSize: 12)),
                ),
              ],
            ),
            for (final section in BackupSection.values)
              CheckboxListTile(
                key: ValueKey('backup.section.${section.name}'),
                dense: true,
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                secondary: vm.selectionSaving
                    ? const SizedBox.square(
                        dimension: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          semanticsLabel: 'Remembering backup selection',
                        ),
                      )
                    : null,
                title: Text(section.label, style: const TextStyle(fontSize: 13)),
                subtitle: _dependencyNote(section, scheme),
                value: vm.selection.contains(section),
                onChanged: working
                    ? null
                    : (value) => vm.toggleSection(section, enabled: value ?? false),
              ),
            const SizedBox(height: 8),
            if (vm.requiresPassphrase)
              Text(
                // Saying *why* rather than just demanding it: a passphrase prompt with no explanation
                // reads as an obstacle, and this one is protecting stored passwords and private keys.
                'This selection contains credentials and host details, so the file will be encrypted '
                'with a passphrase. There is no way to recover the backup without it.',
                key: const ValueKey('backup.sensitiveNote'),
                style: const TextStyle(fontSize: 11, color: OmniColors.amber),
              ),
            const SizedBox(height: 12),
            FilledButton.icon(
              key: const ValueKey('backup.export'),
              icon: const Icon(Icons.upload_file, size: 18),
              label: Text(working ? 'Working…' : 'Create backup'),
              onPressed: vm.canExport && !working ? () => _export(context, vm) : null,
            ),
            const SizedBox(height: 6),
            Text(
              // The whole value of this line is the "Never" case: a user who believes they have a
              // backup and does not is exactly who this screen is for.
              vm.lastExportTimeLoading
                  ? 'Checking last backup time…'
                  : vm.lastExportTimeError != null && vm.lastExportTime == null
                  ? 'Last backup: Unknown'
                  : vm.lastExportTime == null
                  ? 'Last backup: Never'
                  : 'Last backup: ${DateFormat.yMMMd().add_jm().format(vm.lastExportTime!)}',
              key: const ValueKey('backup.lastExport'),
              style: TextStyle(
                fontSize: 11,
                color: vm.lastExportTime == null ? OmniColors.amber : scheme.onSurfaceVariant,
              ),
            ),
            if (vm.lastExportTimeError != null) ...[
              Text(
                vm.lastExportTimeError!,
                style: const TextStyle(fontSize: 11, color: OmniColors.amber),
              ),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  key: const ValueKey('backup.lastExport.retry'),
                  onPressed: vm.loadLastExportTime,
                  child: const Text('Retry checking backup time'),
                ),
              ),
            ],
            const SizedBox(height: 24),
            const SectionHeader(title: 'Restore'),
            Text(
              // The two things a user needs to know before tapping: nothing is destroyed, and the
              // passphrase is not recoverable.
              'Restoring adds the backup\'s contents alongside what is already here — nothing is '
              'deleted or overwritten. An encrypted backup needs the passphrase it was made with.',
              style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              key: const ValueKey('backup.import'),
              icon: const Icon(Icons.restore, size: 18),
              label: const Text('Restore from backup'),
              onPressed: working ? null : () => _import(context, vm),
            ),
          ],
        ),
        if (showProgress) ...[
          const Positioned.fill(child: ModalBarrier(dismissible: false, color: Colors.black38)),
          Center(
            child: Semantics(
              liveRegion: true,
              child: Card(
                key: const ValueKey('backup.progress'),
                margin: const EdgeInsets.all(24),
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      CircularProgressIndicator(semanticsLabel: progressMessage),
                      const SizedBox(height: 16),
                      Text(progressMessage),
                      const SizedBox(height: 8),
                      const Text('This may take a little while. Please wait.'),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }

  Widget? _dependencyNote(BackupSection section, ColorScheme scheme) {
    if (section == BackupSection.crashLogs) {
      return Text(
        'Optional diagnostics; may contain paths or command fragments and always forces encryption.',
        style: TextStyle(fontSize: 10, color: scheme.onSurfaceVariant),
      );
    }
    final dependencies = BackupSelection.dependenciesOf(section);
    if (dependencies.isEmpty) return null;
    // Explaining the coupling before the checkbox moves on its own, which would otherwise look
    // like the app second-guessing the user.
    return Text(
      'Includes ${dependencies.map((d) => d.label.toLowerCase()).join(' and ')}',
      style: TextStyle(fontSize: 10, color: scheme.onSurfaceVariant),
    );
  }

  Future<void> _export(BuildContext context, BackupViewModel vm) async {
    if (_exportPending || vm.busy) return;
    final selection = vm.selection;
    setState(() {
      _exportPending = true;
      // The passphrase dialog already exposes the pending decision; show progress for the
      // platform/IO preparation after it closes, without animating behind the dialog.
      _exportProgress = selection.hasSensitiveData ? null : 'Preparing backup…';
    });
    try {
      await _performExport(context, vm, selection);
    } finally {
      if (mounted) setState(() => _exportPending = false);
    }
  }

  Future<void> _performExport(
    BuildContext context,
    BackupViewModel vm,
    BackupSelection selection,
  ) async {
    var passphrase = '';
    if (selection.hasSensitiveData) {
      final entered = await _askPassphrase(
        context,
        title: 'Choose a passphrase',
        confirmLabel: 'Create backup',
        minLength: BackupViewModel.passphraseMinLength,
        // Stated at the point of decision, where it can still change what the user does.
        note: 'Without this passphrase the backup cannot be opened. Nobody can reset it.',
      );
      if (entered == null) {
        vm.reportCancelled('Backup cancelled — no passphrase was entered. Nothing was written.');
        _revealFeedback();
        return;
      }
      passphrase = entered;
    }

    if (!mounted) return;
    setState(() => _exportProgress = 'Preparing backup…');

    // Sequenced before the export, because the export starts a foreground operation whose
    // permission request would otherwise land on top of the file picker opened moments later.
    // Import does not need this: it opens the picker before any operation begins.
    await vm.operationNotifications?.ensureNotificationPermission();
    if (!context.mounted) return;

    final contents = await vm.exportBackup(passphrase, selection: selection);
    _revealFeedback();
    if (contents == null) return;
    if (!context.mounted) {
      // The backup was built — and encrypted, for a sensitive selection — but the user left before
      // the picker could open, and throwing a system file dialog at a screen they have navigated
      // away from is worse than not saving. Say so rather than dropping it in silence, which is the
      // same mistake the save-outcome switch below used to make.
      vm.reportCancelled(
        'Backup was created but not saved — the screen closed before the file dialog opened. '
        'Nothing was written.',
      );
      return;
    }

    setState(() => _exportProgress = 'Waiting for a save location…');
    final result = await widget.fileStore.save(vm.suggestedFileName(), contents);
    // Deliberately NOT gated on `context.mounted`. Saving hands off to the system file picker — a
    // separate Activity — so this screen is routinely unmounted by the time the file is actually
    // written, and since the engine is retained the view model reliably outlives it. Returning here
    // discarded the outcome of a save that had really happened: no confirmation, no export
    // timestamp stamped, and a failed save equally silent, leaving the user with no evidence the
    // backup existed. `vm` is app-scoped (see main.dart) and always safe to record on; only UI work
    // needs the mounted check, and `_revealFeedback` makes its own.
    switch (result.outcome) {
      case BackupSaveOutcome.saved:
        // Naming where it went, rather than a bare "saved" the user has to take on trust — and
        // repeating the passphrase warning at the moment the file becomes real and portable.
        vm.reportSaved(result.location, encrypted: passphrase.isNotEmpty);
      case BackupSaveOutcome.cancelled:
        // Said, not silent. The backup was already built — and encrypted, for a sensitive
        // selection — behind a "Creating backup…" spinner. Ending that with no message at all left
        // the user unable to tell a cancelled save from a finished one.
        vm.reportSaveCancelled();
      case BackupSaveOutcome.failed:
        vm.reportSaveFailed(result.error);
    }
    _revealFeedback();
  }

  Future<void> _import(BuildContext context, BackupViewModel vm) async {
    String? contents;
    try {
      contents = await widget.fileStore.open();
    } on BackupReadException catch (e) {
      if (context.mounted) vm.reportSaveFailed(e.message);
      _revealFeedback();
      return;
    }
    if (contents == null || !context.mounted) return;
    if (contents.trim().isEmpty) {
      // Picking a file and having nothing happen is the worst of both: the user cannot tell whether
      // the app failed, the file was wrong, or the tap missed.
      vm.reportSaveFailed(
        'That file is empty, so there is nothing to restore. Choose the backup file you exported — '
        'it ends in .json and is usually several kilobytes.',
      );
      _revealFeedback();
      return;
    }

    var passphrase = '';
    if (BackupViewModel.looksEncrypted(contents)) {
      final entered = await _askPassphrase(
        context,
        title: 'Passphrase',
        confirmLabel: 'Restore',
        note: 'The passphrase this backup was created with.',
      );
      if (entered == null) {
        vm.reportCancelled('Restore cancelled — no passphrase was entered. Nothing was changed.');
        _revealFeedback();
        return;
      }
      passphrase = entered;
    }

    final inspection = await vm.inspectBackup(contents, passphrase);
    _revealFeedback();
    if (inspection == null || !context.mounted) return;
    // Read before the dialog: `context` is not safe to use across the await inside it.
    final license = context.read<LicenseController?>();
    final hasHostLimit = isPlayStoreDistribution && !(license?.state.value.unlocked ?? true);
    final choice = await showDialog<_RestoreChoice>(
      context: context,
      builder: (_) => _RestoreSelectionDialog(
        inspection: inspection,
        // A restore writes host rows, so it is bound by the same limit as adding one by hand.
        hasHostLimit: hasHostLimit,
      ),
    );
    if (choice == null) {
      // The file has already been read and decrypted by this point, so "nothing was changed" is
      // the reassurance worth giving.
      vm.reportCancelled('Restore cancelled — nothing was selected. Nothing was changed.');
      _revealFeedback();
      return;
    }
    if (!context.mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        key: const ValueKey('backup.restore.confirmDialog'),
        title: const Text('Restore selected data?'),
        content: const Text(
          'The selected backup contents will be added alongside existing data. This cannot be '
          'undone.',
        ),
        actions: [
          TextButton(
            key: const ValueKey('backup.restore.confirmCancel'),
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const ValueKey('backup.restore.confirm'),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Restore'),
          ),
        ],
      ),
    );
    if (confirmed != true) {
      vm.reportCancelled('Restore cancelled. Nothing was changed.');
      _revealFeedback();
      return;
    }
    await vm.importBackup(
      inspection.plainJson,
      '',
      selection: choice.selection,
      selectedServerIds: choice.hostIds,
    );
    _revealFeedback();
  }
}

@immutable
class _RestoreChoice {
  const _RestoreChoice(this.selection, this.hostIds);

  final BackupSelection selection;
  final Set<int> hostIds;
}

class _RestoreSelectionDialog extends StatefulWidget {
  const _RestoreSelectionDialog({required this.inspection, required this.hasHostLimit});

  final BackupInspection inspection;

  /// True on a free Play build, where saved hosts are capped.
  final bool hasHostLimit;

  @override
  State<_RestoreSelectionDialog> createState() => _RestoreSelectionDialogState();
}

class _RestoreSelectionDialogState extends State<_RestoreSelectionDialog> {
  late BackupSelection _selection = widget.inspection.available;
  late final int? _hostCap = restoreHostCap(
    hasHostLimit: widget.hasHostLimit,
    hostLimit: ServersViewModel.freePlayStoreLimit,
  );
  late Set<int> _hostIds = defaultRestoreHostIds(
    widget.inspection.hosts.map((host) => host.oldId),
    cap: _hostCap,
  );

  /// True when no more hosts may be selected, so the remaining boxes read as unavailable rather
  /// than silently refusing the tap.
  bool get _atCap => _hostCap != null && _hostIds.length >= _hostCap;

  @override
  Widget build(BuildContext context) {
    final available = widget.inspection.available;
    final hostsEnabled = _selection.contains(BackupSection.servers);
    return AlertDialog(
      key: const ValueKey('backup.restore.selectionDialog'),
      title: const Text('Restore backup'),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Choose what to restore from this file.', style: TextStyle(fontSize: 12)),
              const SizedBox(height: 8),
              Row(
                children: [
                  TextButton(
                    key: const ValueKey('backup.restore.all'),
                    onPressed: () => setState(() {
                      _selection = available;
                      _hostIds = defaultRestoreHostIds(
                        widget.inspection.hosts.map((host) => host.oldId),
                        cap: _hostCap,
                      );
                    }),
                    child: const Text('All'),
                  ),
                  TextButton(
                    key: const ValueKey('backup.restore.none'),
                    onPressed: () => setState(() {
                      _selection = const BackupSelection.none();
                      _hostIds = {};
                    }),
                    child: const Text('None'),
                  ),
                ],
              ),
              for (final section in BackupSection.values)
                if (available.contains(section))
                  CheckboxListTile(
                    key: ValueKey('backup.restore.section.${section.name}'),
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    controlAffinity: ListTileControlAffinity.leading,
                    title: Text(section.label, style: const TextStyle(fontSize: 13)),
                    subtitle: Text(
                      '${widget.inspection.counts[section] ?? 0} item(s)',
                      style: const TextStyle(fontSize: 10),
                    ),
                    value: _selection.contains(section),
                    onChanged: (value) => setState(() {
                      _selection = _selection.toggled(section, enabled: value ?? false);
                      if (!_selection.contains(BackupSection.servers)) _hostIds = {};
                    }),
                  ),
              if (hostsEnabled && widget.inspection.hosts.isNotEmpty) ...[
                const Divider(),
                const Text(
                  'Hosts to restore',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                ),
                if (_hostCap != null)
                  Text(
                    // Said before the boxes go grey, not after a tap does nothing.
                    'This build saves $_hostCap host(s). Choose which to restore, or unlock '
                    'OmniTerm to keep them all.',
                    key: const ValueKey('backup.restore.hostCap'),
                    style: const TextStyle(fontSize: 10, color: OmniColors.amber),
                  ),
                for (final host in widget.inspection.hosts)
                  CheckboxListTile(
                    key: ValueKey('backup.restore.host.${host.oldId}'),
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    controlAffinity: ListTileControlAffinity.leading,
                    title: Text(host.name, style: const TextStyle(fontSize: 12)),
                    subtitle: Text(host.host, style: const TextStyle(fontSize: 10)),
                    value: _hostIds.contains(host.oldId),
                    // Disabled rather than silently refusing: at the cap, the boxes that would go
                    // over read as unavailable, and the ones already chosen can still be unchecked
                    // so the user can swap one for another.
                    onChanged: _atCap && !_hostIds.contains(host.oldId)
                        ? null
                        : (value) => setState(() {
                            value == true ? _hostIds.add(host.oldId) : _hostIds.remove(host.oldId);
                          }),
                  ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          key: const ValueKey('backup.restore.cancel'),
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const ValueKey('backup.restore.continue'),
          onPressed:
              _selection.isEmpty ||
                  (hostsEnabled && widget.inspection.hosts.isNotEmpty && _hostIds.isEmpty)
              ? null
              : () => Navigator.pop(context, _RestoreChoice(_selection, _hostIds)),
          child: const Text('Continue'),
        ),
      ],
    );
  }
}

Future<String?> _askPassphrase(
  BuildContext context, {
  required String title,
  required String confirmLabel,
  required String note,
  int minLength = 0,
}) => showDialog<String>(
  context: context,
  builder: (_) => _PromptDialog(
    dialogKey: 'backup.passphrase',
    title: title,
    note: note,
    confirmLabel: confirmLabel,
    obscure: true,
    minLength: minLength,
  ),
);

/// Asks for one value. Owns its controller so it dies with the dialog.
class _PromptDialog extends StatefulWidget {
  const _PromptDialog({
    required this.dialogKey,
    required this.title,
    required this.confirmLabel,
    this.note,
    this.obscure = false,
    this.minLength = 0,
  });

  final String dialogKey;
  final String title;
  final String confirmLabel;
  final String? note;
  final bool obscure;

  /// Shortest accepted value. The confirm button stays disabled below it, so the dialog cannot hand
  /// back something the caller will refuse — which is the shape of the defect this fixes.
  final int minLength;

  @override
  State<_PromptDialog> createState() => _PromptDialogState();
}

class _PromptDialogState extends State<_PromptDialog> {
  final _controller = TextEditingController();

  bool get _longEnough => _controller.text.length >= widget.minLength;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      key: ValueKey('${widget.dialogKey}.dialog'),
      // Scrollable because the content is a multi-child Column with no scroll of its own: on a
      // small phone in landscape at 200% text it does not fit, and an AlertDialog clips rather
      // than scrolls unless it is asked to. Same shape as parity defects 112 and 113.
      scrollable: true,
      title: Text(widget.title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (widget.note != null) ...[
            Text(widget.note!, style: const TextStyle(fontSize: 11)),
            const SizedBox(height: 10),
          ],
          TextField(
            key: ValueKey('${widget.dialogKey}.field'),
            controller: _controller,
            autofocus: true,
            obscureText: widget.obscure,
            onChanged: (_) => setState(() {}),
            decoration: omniInputDecoration(
              context,
              // The requirement is on the field, not in an error after the fact. A user who is told
              // the number while typing never meets the refusal.
              labelText: widget.minLength > 0 ? 'At least ${widget.minLength} characters' : null,
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          key: ValueKey('${widget.dialogKey}.cancel'),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        TextButton(
          key: ValueKey('${widget.dialogKey}.confirm'),
          onPressed: _longEnough ? () => Navigator.of(context).pop(_controller.text) : null,
          child: Text(widget.confirmLabel),
        ),
      ],
    );
  }
}
