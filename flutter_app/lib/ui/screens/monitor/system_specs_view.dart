import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../data/app_database.dart';
import '../../../data/system_specs.dart';
import '../../../l10n/app_localizations.dart';
import '../../theme/colors.dart';
import '../../theme/typography.dart';
import '../../view_model/app_lock_controller.dart';
import '../../view_model/system_specs_view_model.dart';
import '../../widgets/copy_with_confirmation.dart';
import '../../widgets/host_tool_notice.dart';
import '../../widgets/omni_components.dart';
import '../../widgets/sudo_auth_dialog.dart';

/// A host's system specs as collapsible sections, each with its devices collapsible inside it.
/// Ported from `ui/SystemSpecsView.kt`: the one view behind Monitor › Specs and the Hosts tab's
/// pop-up.

const _titles = {
  SpecKind.system: 'System',
  SpecKind.cpu: 'Processor',
  SpecKind.memory: 'Memory',
  SpecKind.storage: 'Storage',
  SpecKind.gpu: 'Graphics',
  SpecKind.network: 'Network',
};

const _icons = {
  SpecKind.system: Icons.computer,
  SpecKind.cpu: Icons.developer_board,
  SpecKind.memory: Icons.memory,
  SpecKind.storage: Icons.storage,
  SpecKind.gpu: Icons.monitor,
  SpecKind.network: Icons.lan,
};

/// What each notice says, in Kotlin's words (`SystemSpecsView.kt`, generated from its strings).
String _noticeText(AppLocalizations l10n, SpecNotice notice) => switch (notice) {
  SpecNotice.modulesNeedRoot => l10n.specModulesNeedRoot,
  SpecNotice.modulesToolMissing => l10n.specModulesToolMissing,
  SpecNotice.noModulesReported => l10n.specNoModulesReported,
  SpecNotice.driveHealthNeedsRoot => l10n.specDriveHealthNeedsRoot,
  SpecNotice.driveHealthToolMissing => l10n.specDriveHealthToolMissing,
  SpecNotice.gpuToolMissing => l10n.specGpuToolMissing,
};

/// The sheet for [server]: a header with copy and refresh, then the sections.
///
/// [fill] lets the list take the remaining height (Monitor's tab); otherwise it sizes to its
/// content up to what the surrounding dialog allows.
class SystemSpecsContent extends StatelessWidget {
  const SystemSpecsContent({super.key, required this.server, this.fill = false});

  final Server server;
  final bool fill;

  @override
  Widget build(BuildContext context) {
    final vm = context.watch<SystemSpecsViewModel>();
    final state = vm.stateFor(server.id);
    final specs = state?.specs;
    final error = state?.error;
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;

    final Widget body;
    if (specs == null && error != null) {
      body = Padding(
        padding: const EdgeInsets.symmetric(vertical: 24),
        child: Column(
          children: [
            Text(
              'Could not read the specs: $error',
              key: const ValueKey('specs.error'),
              style: const TextStyle(color: OmniColors.red, fontSize: 11),
            ),
            TextButton(onPressed: () => vm.load(server), child: const Text('Retry')),
          ],
        ),
      );
    } else if (specs == null) {
      body = Padding(
        padding: const EdgeInsets.symmetric(vertical: 32),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox.square(dimension: 28, child: CircularProgressIndicator()),
              const SizedBox(height: 8),
              Text('Reading system specs…', style: TextStyle(color: muted, fontSize: 11)),
            ],
          ),
        ),
      );
    } else {
      final uptime = specs.uptimeSeconds;
      final list = ListView(
        key: const ValueKey('specs.sections'),
        shrinkWrap: !fill,
        children: [
          if (error != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                'Could not read the specs: $error',
                style: const TextStyle(color: OmniColors.red, fontSize: 11),
              ),
            ),
          if (specs.wouldGainFromSudo || specs.sudoError != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: _SudoBanner(server: server, sudoError: specs.sudoError),
            ),
          for (final section in specs.sections)
            Padding(
              key: ValueKey('specs.section.${section.kind.name}'),
              padding: const EdgeInsets.only(bottom: 8),
              child: _SectionCard(
                server: server,
                section: section,
                extraFields: [
                  if (section.kind == SpecKind.system && uptime != null)
                    SpecField('Uptime', formatUptime(uptime)),
                ],
              ),
            ),
        ],
      );
      body = fill ? Expanded(child: list) : Flexible(child: list);
    }

    return Column(
      mainAxisSize: fill ? MainAxisSize.max : MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                'Hardware and software of ${server.name}',
                style: TextStyle(color: muted, fontSize: 11),
              ),
            ),
            if (specs != null)
              IconButton(
                key: const ValueKey('specs.copy'),
                tooltip: 'Copy all specs',
                icon: const Icon(Icons.content_copy),
                onPressed: () => copyWithConfirmation(context, specs.asText((k) => _titles[k]!)),
              ),
            IconButton(
              key: const ValueKey('specs.refresh'),
              tooltip: 'Read specs again',
              icon: const Icon(Icons.refresh),
              onPressed: state?.loading == true ? null : () => vm.load(server),
            ),
          ],
        ),
        if (state?.loading == true && specs != null) const LinearProgressIndicator(),
        body,
      ],
    );
  }
}

class _SudoBanner extends StatelessWidget {
  const _SudoBanner({required this.server, required this.sudoError});

  final Server server;
  final String? sudoError;

  @override
  Widget build(BuildContext context) {
    final error = sudoError;
    return Container(
      key: const ValueKey('specs.sudoBanner'),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: OmniColors.amber.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Memory modules and drive health can only be read as root.',
            style: TextStyle(fontSize: 11),
          ),
          if (error != null) ...[
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                'sudo said: $error',
                style: const TextStyle(color: OmniColors.red, fontSize: 11),
              ),
            ),
            if (server.sudoPassword.trim().isEmpty)
              Text(
                'No sudo password is saved for this host. Add one under Edit host, or allow '
                'dmidecode and smartctl without a password.',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                  fontSize: 11,
                ),
              ),
          ],
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: OutlinedButton(
              key: const ValueKey('specs.readWithSudo'),
              onPressed: () => readSpecsWithSudo(context, server),
              child: const Text('Read with sudo'),
            ),
          ),
        ],
      ),
    );
  }
}

/// Reads again with sudo, behind the same check as every other use of sudo.
Future<void> readSpecsWithSudo(BuildContext context, Server server) async {
  final vm = context.read<SystemSpecsViewModel>();
  final lock = context.read<AppLockController>();
  if (!await requestSudoAuth(context, lock, hostName: server.name)) return;
  await vm.load(server, withSudo: true);
}

class _SectionCard extends StatelessWidget {
  const _SectionCard({required this.server, required this.section, required this.extraFields});

  final Server server;
  final SpecSection section;
  final List<SpecField> extraFields;

  @override
  Widget build(BuildContext context) {
    final vm = context.watch<SystemSpecsViewModel>();
    final key = section.kind.name;
    final expanded = vm.isExpanded(server.id, key);
    return OmniCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _ExpandableHeader(
            expanded: expanded,
            onToggle: () => vm.toggleExpanded(server.id, key),
            title: _titles[section.kind]!,
            summary: section.summary,
            icon: _icons[section.kind],
          ),
          if (expanded)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final field in [...extraFields, ...section.fields])
                    Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: _FieldRow(field: field),
                    ),
                  for (final item in section.items)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: _ItemCard(server: server, sectionKey: key, item: item),
                    ),
                  for (final notice in section.notices)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: switch (notice.tool) {
                        // Reads again as the specs were read, so a read with sudo stays one.
                        final tool? => HostToolNotice(
                          server: server,
                          tool: tool,
                          text: _noticeText(AppLocalizations.of(context), notice),
                          onInstalled: () => unawaited(vm.load(server)),
                        ),
                        null => Text(
                          _noticeText(AppLocalizations.of(context), notice),
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.onSurfaceVariant,
                            fontSize: 11,
                          ),
                        ),
                      },
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _ItemCard extends StatelessWidget {
  const _ItemCard({required this.server, required this.sectionKey, required this.item});

  final Server server;
  final String sectionKey;
  final SpecItem item;

  @override
  Widget build(BuildContext context) {
    final vm = context.watch<SystemSpecsViewModel>();
    final key = '$sectionKey/${item.title}';
    final expandable = item.fields.isNotEmpty;
    final expanded = expandable && vm.isExpanded(server.id, key);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _ExpandableHeader(
            expanded: expanded,
            onToggle: expandable ? () => vm.toggleExpanded(server.id, key) : null,
            title: item.title,
            summary: item.summary,
            showChevron: expandable,
          ),
          if (expanded)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final field in item.fields)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 3),
                      child: _FieldRow(field: field),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _ExpandableHeader extends StatelessWidget {
  const _ExpandableHeader({
    required this.expanded,
    required this.onToggle,
    required this.title,
    required this.summary,
    this.icon,
    this.showChevron = true,
  });

  final bool expanded;
  final VoidCallback? onToggle;
  final String title;
  final String summary;
  final IconData? icon;
  final bool showChevron;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onToggle,
      child: Row(
        children: [
          if (icon != null) ...[
            Icon(icon, size: 20, color: OmniColors.cyan),
            const SizedBox(width: 10),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                if (summary.isNotEmpty)
                  Text(
                    summary,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                      fontSize: 11,
                    ),
                  ),
              ],
            ),
          ),
          if (showChevron)
            Icon(
              expanded ? Icons.keyboard_arrow_down : Icons.keyboard_arrow_right,
              semanticLabel: expanded ? 'Collapse' : 'Expand',
            ),
        ],
      ),
    );
  }
}

class _FieldRow extends StatelessWidget {
  const _FieldRow({required this.field});

  final SpecField field;

  @override
  Widget build(BuildContext context) {
    if (field.label.isEmpty) {
      return SelectableText(
        field.value,
        style: const TextStyle(fontFamily: OmniFonts.mono, fontSize: 11),
      );
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          flex: 42,
          child: Padding(
            padding: const EdgeInsets.only(right: 8),
            child: SelectableText(
              field.label,
              style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 11),
            ),
          ),
        ),
        Expanded(
          flex: 58,
          child: SelectableText(field.value, style: const TextStyle(fontSize: 11)),
        ),
      ],
    );
  }
}

/// The Hosts tab's pop-up for ⋮ › System specs. Reads the host's specs unless they are already
/// shown or on their way.
Future<void> showSystemSpecsDialog(BuildContext context, Server server) {
  context.read<SystemSpecsViewModel>().loadIfNeeded(server);
  return showDialog<void>(
    context: context,
    builder: (dialogContext) => Dialog(
      key: const ValueKey('specs.dialog'),
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560, maxHeight: 720),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('System specs', style: Theme.of(dialogContext).textTheme.titleLarge),
              Flexible(child: SystemSpecsContent(server: server)),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(),
                  child: const Text('Close'),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

/// Monitor › Specs: reads the selected host's specs the first time it is shown.
class SpecsTab extends StatefulWidget {
  const SpecsTab({super.key, required this.server});

  final Server server;

  @override
  State<SpecsTab> createState() => _SpecsTabState();
}

class _SpecsTabState extends State<SpecsTab> {
  @override
  void initState() {
    super.initState();
    _loadIfNeeded();
  }

  @override
  void didUpdateWidget(SpecsTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.server.id != widget.server.id) _loadIfNeeded();
  }

  // After the frame: loading notifies listeners, which must not happen while this tree builds.
  void _loadIfNeeded() => WidgetsBinding.instance.addPostFrameCallback((_) {
    if (mounted) context.read<SystemSpecsViewModel>().loadIfNeeded(widget.server);
  });

  @override
  Widget build(BuildContext context) => SystemSpecsContent(server: widget.server, fill: true);
}
