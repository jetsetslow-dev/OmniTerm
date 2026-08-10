import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../data/app_database.dart';
import '../../../data/remote_models.dart';
import '../../../domain/host_display.dart';
import '../../../domain/external_ui_requests.dart';
import '../../../domain/measurement_units.dart';
import '../../../platform/distribution.dart';
import '../../../platform/license_controller.dart';
import '../../../platform/shortcut_helper.dart';
import '../../navigation.dart';
import '../../theme/colors.dart';
import '../../theme/typography.dart';
import '../../view_model/servers_view_model.dart';
import '../../view_model/host_status_probe.dart';
import '../../view_model/sftp_view_model.dart';
import '../../view_model/shell_view_model.dart';
import '../../view_model/telemetry_poller.dart';
import '../../widgets/health_breakdown_dialog.dart';
import '../../widgets/omni_components.dart';
import '../../widgets/license_gate.dart';
import 'server_form_sheet.dart';
import 'server_form_state.dart';

/// The Servers screen, ported from `ServersMainView` in `ui/AppUi.kt`.
///
/// Every interactive element carries a stable [Key] (`ValueKey('servers.…')`). That is a
/// requirement, not a style choice: the Patrol suite has to target these on both platforms, and
/// Flutter paints its own pixels so there is no native view tree to fall back on. Adding the keys
/// while a screen is written costs nothing; retrofitting them across 36k LOC does not.
class ServersScreen extends StatelessWidget {
  const ServersScreen({
    super.key,
    this.licenseController,
    this.externalUiRequests,
    this.navigation,
    this.telemetry,
    this.hostProbe,
    this.shell,
    this.sftp,
    this.shortcuts,
  });

  final LicenseController? licenseController;
  final ExternalUiRequests? externalUiRequests;
  final NavigationController? navigation;
  final TelemetryPoller? telemetry;
  final HostStatusProbe? hostProbe;
  final ShellViewModel? shell;
  final SftpViewModel? sftp;
  final ShortcutHelper? shortcuts;

  @override
  Widget build(BuildContext context) {
    final vm = context.watch<ServersViewModel>();
    final filtered = vm.filteredServers;
    final license = licenseController;
    if (license == null) {
      return _buildBody(context, vm, filtered, null, false);
    }

    return ValueListenableBuilder<LicenseState>(
      valueListenable: license.state,
      builder: (context, state, _) {
        final atLimit = vm.hostLimitReached(
          playStoreBuild: isPlayStoreDistribution,
          unlocked: state.unlocked,
        );
        return _buildBody(context, vm, filtered, license, atLimit);
      },
    );
  }

  Widget _buildBody(
    BuildContext context,
    ServersViewModel vm,
    List<Server> filtered,
    LicenseController? license,
    bool atLimit,
  ) => Stack(
    children: [
      Column(
        children: [
          _SummaryBanner(servers: vm.servers),
          if (atLimit)
            _LimitNotice(
              onUnlock: () => showPremiumGate(
                context,
                controller: license!,
                title: 'Saved host limit reached',
                message:
                    'The free Play Store build supports one saved host. Unlock OmniTerm '
                    'to add unlimited hosts.',
              ),
            ),
          _SearchRow(vm: vm),
          _GroupChips(vm: vm),
          if (vm.isMultiSelectMode) _BulkActions(vm: vm),
          Expanded(
            child: filtered.isEmpty
                ? _EmptyState(hasServers: vm.servers.isNotEmpty)
                : ListView.builder(
                    key: const ValueKey('servers.list'),
                    padding: const EdgeInsets.fromLTRB(10, 0, 10, 88),
                    itemCount: filtered.length,
                    itemBuilder: (context, index) => _ServerCard(
                      server: filtered[index],
                      vm: vm,
                      navigation: navigation,
                      metrics: telemetry?.metricsForServer(filtered[index].id),
                      hostProbe: hostProbe,
                      shell: shell,
                      sftp: sftp,
                      shortcuts: shortcuts,
                    ),
                  ),
          ),
        ],
      ),
      Positioned(
        right: 16,
        bottom: 16,
        child: FloatingActionButton(
          key: const ValueKey('servers.add'),
          tooltip: 'Add host',
          onPressed: atLimit
              ? () => showPremiumGate(
                  context,
                  controller: license!,
                  title: 'Saved host limit reached',
                  message:
                      'The free Play Store build supports one saved host. Unlock OmniTerm '
                      'to add unlimited hosts.',
                )
              : () => openServerForm(context, vm, mode: ServerFormMode.add),
          child: const Icon(Icons.add),
        ),
      ),
      if (externalUiRequests != null)
        _ExternalAddServerRequest(
          vm: vm,
          license: license,
          atLimit: atLimit,
          requests: externalUiRequests!,
        ),
    ],
  );
}

class _ExternalAddServerRequest extends StatefulWidget {
  const _ExternalAddServerRequest({
    required this.vm,
    required this.license,
    required this.atLimit,
    required this.requests,
  });

  final ServersViewModel vm;
  final LicenseController? license;
  final bool atLimit;
  final ExternalUiRequests requests;

  @override
  State<_ExternalAddServerRequest> createState() => _ExternalAddServerRequestState();
}

class _ExternalAddServerRequestState extends State<_ExternalAddServerRequest> {
  bool _scheduled = false;

  @override
  Widget build(BuildContext context) {
    final requests = widget.requests;
    if (requests.hasAddServerRequest && !_scheduled) {
      _scheduled = true;
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        final request = requests.takeAddServerRequest();
        if (!mounted || request == null) {
          _scheduled = false;
          return;
        }
        if (widget.atLimit && widget.license != null) {
          await showPremiumGate(
            context,
            controller: widget.license!,
            title: 'Saved host limit reached',
            message:
                'The free Play Store build supports one saved host. Unlock OmniTerm '
                'to add unlimited hosts.',
          );
        } else {
          await openServerForm(
            context,
            widget.vm,
            mode: ServerFormMode.add,
            prefillHost: request.host,
            prefillPort: request.port,
            suggestedName: request.suggestedName,
          );
        }
        _scheduled = false;
        if (mounted && requests.hasAddServerRequest) setState(() {});
      });
    }
    return const SizedBox.shrink();
  }
}

class _LimitNotice extends StatelessWidget {
  const _LimitNotice({required this.onUnlock});

  final VoidCallback onUnlock;

  @override
  Widget build(BuildContext context) => Container(
    key: const ValueKey('servers.limit'),
    width: double.infinity,
    color: OmniColors.amber.withValues(alpha: 0.12),
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
    child: Row(
      children: [
        const Expanded(child: Text('Free plan host limit reached', style: TextStyle(fontSize: 11))),
        TextButton(onPressed: onUnlock, child: const Text('Unlock')),
      ],
    ),
  );
}

/// Opens the add/edit/duplicate sheet.
///
/// Exposed so the card's edit action and the FAB share one entry point rather than each wiring the
/// repository call themselves.
Future<void> openServerForm(
  BuildContext context,
  ServersViewModel vm, {
  required ServerFormMode mode,
  Server? source,
  String? prefillHost,
  int? prefillPort,
  String? suggestedName,
}) async {
  // Read the saved key aliases before opening: the form's Auth tab offers them, and a picker with
  // no options would make a key-authenticated host impossible to create.
  final aliases = (await vm.savedKeyAliases()).toList();
  if (!context.mounted) return;
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => ServerFormSheet(
      mode: mode,
      source: source,
      prefillHost: prefillHost,
      prefillPort: prefillPort,
      suggestedName: suggestedName,
      existingServers: vm.servers,
      savedKeyAliases: aliases,
      onSave: (server) =>
          mode == ServerFormMode.edit ? vm.updateServer(server) : vm.saveServer(server),
      onTestConnection: vm.canTestConnections ? vm.testConnection : null,
    ),
  );
}

/// Total / online / offline / groups, the at-a-glance fleet summary.
class _SummaryBanner extends StatelessWidget {
  const _SummaryBanner({required this.servers});

  final List<Server> servers;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final online = servers.where((s) => s.status == 'online').length;
    final offline = servers.where((s) => s.status == 'offline').length;
    final groups = servers.map((s) => s.groupName).whereType<String>().toSet().length;

    return OmniCard(
      key: const ValueKey('servers.summary'),
      margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
      child: Row(
        children: [
          Expanded(
            child: OmniStatBox(value: '${servers.length}', label: 'Total'),
          ),
          Expanded(
            child: OmniStatBox(value: '$online', label: 'Online', color: OmniColors.green),
          ),
          Expanded(
            child: OmniStatBox(
              value: '$offline',
              label: 'Offline',
              // Only red when something is actually down; a permanent red zero is noise the eye
              // learns to ignore.
              color: offline > 0 ? OmniColors.red : scheme.onSurfaceVariant,
            ),
          ),
          Expanded(
            child: OmniStatBox(value: '$groups', label: 'Groups', color: OmniColors.cyan),
          ),
        ],
      ),
    );
  }
}

class _SearchRow extends StatefulWidget {
  const _SearchRow({required this.vm});

  final ServersViewModel vm;

  @override
  State<_SearchRow> createState() => _SearchRowState();
}

class _SearchRowState extends State<_SearchRow> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.vm.serverSearchText,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final vm = widget.vm;
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              key: const ValueKey('servers.search'),
              controller: _controller,
              onChanged: (value) => vm.serverSearchText = value,
              decoration: omniInputDecoration(
                context,
                hintText: 'Search hosts',
                prefixIcon: const Icon(Icons.search, size: 20),
                suffixIcon: vm.serverSearchText.isEmpty
                    ? null
                    : IconButton(
                        tooltip: 'Clear search',
                        key: const ValueKey('servers.search.clear'),
                        icon: const Icon(Icons.close, size: 18),
                        onPressed: () {
                          _controller.clear();
                          vm.serverSearchText = '';
                        },
                      ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          IconButton(
            key: const ValueKey('servers.multiSelect.toggle'),
            tooltip: vm.isMultiSelectMode ? 'Exit multi-select' : 'Select multiple hosts',
            onPressed: () => vm.isMultiSelectMode = !vm.isMultiSelectMode,
            icon: Icon(
              vm.isMultiSelectMode ? Icons.close : Icons.checklist,
              color: vm.isMultiSelectMode ? OmniColors.cyan : null,
            ),
          ),
        ],
      ),
    );
  }
}

class _GroupChips extends StatelessWidget {
  const _GroupChips({required this.vm});

  final ServersViewModel vm;

  @override
  Widget build(BuildContext context) {
    final chips = vm.groupChips;
    // A fleet with no groups needs no filter bar at all.
    if (chips.length <= 1) return const SizedBox.shrink();

    return SizedBox(
      height: 40,
      child: ListView.separated(
        key: const ValueKey('servers.groupChips'),
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
        itemCount: chips.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          final group = chips[index];
          return FilterChip(
            key: ValueKey('servers.groupChip.$group'),
            label: Text(group),
            selected: vm.selectedGroupChip == group,
            onSelected: (_) => vm.selectedGroupChip = group,
          );
        },
      ),
    );
  }
}

class _BulkActions extends StatelessWidget {
  const _BulkActions({required this.vm});

  final ServersViewModel vm;

  @override
  Widget build(BuildContext context) => Container(
    key: const ValueKey('servers.bulkActions'),
    margin: const EdgeInsets.fromLTRB(12, 4, 12, 8),
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.secondaryContainer,
      borderRadius: BorderRadius.circular(8),
    ),
    child: Row(
      children: [
        Expanded(child: Text('${vm.selectedServerIdsForBulk.length} servers selected')),
        TextButton(
          key: const ValueKey('servers.bulk.selectAll'),
          onPressed: vm.selectAllServers,
          child: const Text('Select all'),
        ),
        TextButton(
          key: const ValueKey('servers.bulk.group'),
          onPressed: vm.selectedServerIdsForBulk.isEmpty ? null : () => _showGroupDialog(context),
          child: const Text('Group'),
        ),
        IconButton(
          key: const ValueKey('servers.bulk.delete'),
          tooltip: 'Delete selected',
          onPressed: vm.selectedServerIdsForBulk.isEmpty ? null : () => _confirmBulkDelete(context),
          icon: const Icon(Icons.delete_outline, color: OmniColors.red),
        ),
      ],
    ),
  );

  Future<void> _showGroupDialog(BuildContext context) async {
    final controller = TextEditingController(
      text: vm.selectedGroupChip == 'All' ? '' : vm.selectedGroupChip,
    );
    final group = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Assign group'),
        content: TextField(
          key: const ValueKey('servers.bulk.groupName'),
          controller: controller,
          autofocus: true,
          decoration: omniInputDecoration(
            context,
            labelText: 'Group name',
            helperText: 'Type a new group or reuse an existing name.',
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(
            key: const ValueKey('servers.bulk.groupSave'),
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('Apply'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (group != null && group.isNotEmpty) await vm.setGroupForSelected(group);
  }

  Future<void> _confirmBulkDelete(BuildContext context) async {
    final count = vm.selectedServerIdsForBulk.length;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Delete $count hosts?'),
        content: const Text(
          'Remove these host connections and their saved credentials from OmniTerm? '
          'This does not affect the remote machines and cannot be undone here.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(
            key: const ValueKey('servers.bulk.deleteConfirm'),
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(backgroundColor: OmniColors.red),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed == true) await vm.deleteSelectedServers();
  }
}

class _ServerCard extends StatelessWidget {
  const _ServerCard({
    required this.server,
    required this.vm,
    this.navigation,
    this.metrics,
    this.hostProbe,
    this.shell,
    this.sftp,
    this.shortcuts,
  });

  final Server server;
  final ServersViewModel vm;
  final NavigationController? navigation;
  final HostMetrics? metrics;
  final HostStatusProbe? hostProbe;
  final ShellViewModel? shell;
  final SftpViewModel? sftp;
  final ShortcutHelper? shortcuts;

  @override
  Widget build(BuildContext context) {
    // HostDisplay must be *listened* to, not merely read. In Compose it was an observable
    // `mutableStateOf`, so every reader recomposed on change; a Flutter widget that reads a
    // ChangeNotifier without subscribing simply never rebuilds — and "Hide sensitive info" would
    // appear to do nothing until some unrelated change happened to repaint the row.
    return ListenableBuilder(
      listenable: HostDisplay.instance,
      builder: (context, _) => _buildCard(context),
    );
  }

  Widget _buildCard(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final display = HostDisplay.instance;
    final accent = OmniColors.serverAccent(server.serverColor, server.name);
    final ticked = vm.selectedServerIdsForBulk.contains(server.id);

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: OmniCard(
        key: ValueKey('servers.card.${server.id}'),
        leftAccent: accent,
        semanticLabel: '${server.name}, ${_statusLabel(server)}',
        onTap: () {
          if (vm.isMultiSelectMode) {
            vm.toggleBulkSelection(server.id);
          } else {
            vm.selectedServerId = server.id;
            navigation?.navigateTo(Screen.monitor);
          }
        },
        onLongPress: vm.isMultiSelectMode
            ? null
            : () {
                vm.isMultiSelectMode = true;
                vm.toggleBulkSelection(server.id);
              },
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                if (vm.isMultiSelectMode)
                  Checkbox(
                    key: ValueKey('servers.card.${server.id}.check'),
                    value: ticked,
                    onChanged: (_) => vm.toggleBulkSelection(server.id),
                  ),
                _StatusDot(server: server),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    display.name(server),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: scheme.onSurface,
                      fontWeight: FontWeight.bold,
                      fontFamily: OmniFonts.mono,
                      fontSize: 16,
                    ),
                  ),
                ),
                Text(
                  server.status == 'online'
                      ? '${server.lastLatency}ms'
                      : server.status == 'connecting'
                      ? '…'
                      : 'Offline',
                  style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12),
                ),
                const SizedBox(width: 8),
                InkWell(
                  key: ValueKey('servers.card.${server.id}.health'),
                  onTap: () => showHealthBreakdown(
                    context,
                    name: server.name,
                    breakdown: vm.healthBreakdown(server, metrics),
                  ),
                  child: _HealthRing(score: server.status == 'online' ? server.healthScore : 0),
                ),
                IconButton(
                  key: ValueKey('servers.card.${server.id}.actions'),
                  tooltip: 'Actions',
                  onPressed: () => _showActions(context),
                  icon: const Icon(Icons.more_vert),
                ),
              ],
            ),
            Row(
              children: [
                Expanded(
                  child: Row(
                    children: [
                      Flexible(
                        child: Text(
                          display.userAtHost(server),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13),
                        ),
                      ),
                      Text(
                        ':${server.port}',
                        style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13),
                      ),
                    ],
                  ),
                ),
                if (server.groupName?.trim().isNotEmpty == true)
                  OmniTag(label: server.groupName!, color: scheme.onSurfaceVariant),
              ],
            ),
            if (server.notes.trim().isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(
                server.notes,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: scheme.onSurfaceVariant,
                  fontStyle: FontStyle.italic,
                  fontSize: 12,
                ),
              ),
            ],
            const SizedBox(height: 8),
            if (server.status == 'online' && server.authStatus == 'failed')
              _AuthFailure(server: server, onRetry: () => hostProbe?.probeOne(server))
            else if (server.status == 'online') ...[
              Row(
                children: [
                  Expanded(
                    child: _MiniMetric(label: 'CPU', value: metrics?.cpuPercent ?? 0),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _MiniMetric(label: 'RAM', value: metrics?.memPercent ?? 0),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _MiniMetric(label: 'DISK', value: metrics?.diskPercent ?? 0),
                  ),
                  if (metrics?.cpuTempC case final temp?) ...[
                    const SizedBox(width: 8),
                    Expanded(
                      child: _MiniMetric(
                        label: 'TEMP',
                        value: temp,
                        display:
                            '${celsiusToDisplay(temp, vm.measurementSystem).round()}'
                            '${temperatureUnit(vm.measurementSystem)}',
                      ),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 8),
              Wrap(
                alignment: WrapAlignment.spaceBetween,
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 8,
                runSpacing: 6,
                children: [
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.circle, size: 6, color: OmniColors.green),
                      const SizedBox(width: 5),
                      // Flexible so the row can give way. It sits in a `Wrap` with
                      // `mainAxisSize: min`, which asks for the text's full width — at 200% text
                      // "online · ssh not verified yet" is fractionally wider than the line and the
                      // row overflowed by 0.8px. Nothing can shrink inside it otherwise.
                      Flexible(
                        child: Text(
                          server.authStatus == 'ok'
                              ? 'authenticated'
                              : 'online · ssh not verified yet',
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: server.authStatus == 'ok' ? OmniColors.green : OmniColors.amber,
                            fontFamily: OmniFonts.mono,
                            fontSize: 10,
                          ),
                        ),
                      ),
                    ],
                  ),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _CardAction(
                        label: 'SSH',
                        onPressed: shell == null ? null : () => _connect(context),
                      ),
                      const SizedBox(width: 5),
                      _CardAction(label: 'SFTP', onPressed: sftp == null ? null : _openSftp),
                      const SizedBox(width: 5),
                      _CardAction(label: 'DOCKER', onPressed: () => _navigate(Screen.infra)),
                    ],
                  ),
                ],
              ),
            ] else if (server.status == 'connecting')
              Row(
                children: [
                  const SizedBox.square(
                    dimension: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(width: 8),
                  Text('Checking host…', style: TextStyle(color: scheme.onSurfaceVariant)),
                ],
              )
            else
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'OFFLINE / UNREACHABLE',
                          style: TextStyle(
                            color: OmniColors.red,
                            fontWeight: FontWeight.bold,
                            fontSize: 11,
                          ),
                        ),
                        Text(
                          'No TCP route to ${display.host(server)}:${server.port}',
                          style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 10),
                        ),
                      ],
                    ),
                  ),
                  _CardAction(
                    label: 'Retry',
                    color: OmniColors.red,
                    onPressed: hostProbe == null ? null : () => hostProbe!.probeOne(server),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }

  void _navigate(Screen target) {
    vm.selectedServerId = server.id;
    navigation?.navigateTo(target);
  }

  void _openSftp() {
    vm.selectedServerId = server.id;
    sftp!.activeTab = SftpTab.files;
    navigation?.navigateTo(Screen.sftp);
  }

  Future<void> _connect(BuildContext context) async {
    // The "appears offline" confirmation is **not** here: it lives in `ShellViewModel.connect`, so
    // every route to a terminal is covered rather than this one button. Kotlin gates it in
    // `connectTerminal` for the same reason (`ui/AppViewModel.kt:4496`).
    vm.selectedServerId = server.id;
    navigation?.navigateTo(Screen.shell);
    await shortcuts?.pushServer(server);
    await shortcuts?.reportServerUsed(server.id);
    await shell?.connect(server, controlMode: shell!.useControlMode);
  }

  Future<void> _showActions(BuildContext context) async {
    final action = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text(server.name),
        children: [
          _DialogAction(value: 'edit', icon: Icons.edit, label: 'Edit server configuration'),
          _DialogAction(
            value: 'duplicate',
            icon: Icons.content_copy,
            label: 'Duplicate host · reuse credentials',
          ),
          if (shortcuts != null)
            _DialogAction(value: 'pin', icon: Icons.push_pin, label: 'Pin to home screen'),
          if (shell != null)
            _DialogAction(value: 'shell', icon: Icons.terminal, label: 'Open terminal console'),
          _DialogAction(value: 'monitor', icon: Icons.speed, label: 'Monitor live metrics'),
          _DialogAction(value: 'infra', icon: Icons.layers, label: 'Infrastructure / containers'),
          const _DialogAction(
            value: 'delete',
            icon: Icons.delete,
            label: 'Delete server host connection',
            destructive: true,
          ),
        ],
      ),
    );
    if (!context.mounted || action == null) return;
    switch (action) {
      case 'edit':
        await openServerForm(context, vm, mode: ServerFormMode.edit, source: server);
      case 'duplicate':
        await openServerForm(context, vm, mode: ServerFormMode.duplicate, source: server);
      case 'pin':
        final pinned = await shortcuts?.pinServer(server) ?? false;
        if (context.mounted && !pinned) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('This launcher does not support pinned shortcuts.')),
          );
        }
      case 'shell':
        await _connect(context);
      case 'monitor':
        _navigate(Screen.monitor);
      case 'infra':
        _navigate(Screen.infra);
      case 'delete':
        await _confirmDelete(context);
    }
  }

  Future<void> _confirmDelete(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Delete ${server.name}?'),
        content: const Text(
          'Remove this host connection and its saved credentials from OmniTerm? '
          'This does not affect the remote machine, but cannot be undone here.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(backgroundColor: OmniColors.red),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed == true) await vm.deleteServer(server.id);
  }

  String _statusLabel(Server server) {
    // Auth state is reported separately from reachability: a host can answer on the port and still
    // reject the credentials, and calling that "online" would send the user hunting the wrong fault.
    if (server.authStatus == 'failed') return 'authentication failed';
    return server.status;
  }
}

class _DialogAction extends StatelessWidget {
  const _DialogAction({
    required this.value,
    required this.icon,
    required this.label,
    this.destructive = false,
  });

  final String value;
  final IconData icon;
  final String label;
  final bool destructive;

  @override
  Widget build(BuildContext context) => SimpleDialogOption(
    onPressed: () => Navigator.pop(context, value),
    child: Row(
      children: [
        Icon(icon, color: destructive ? OmniColors.red : null),
        const SizedBox(width: 10),
        Expanded(
          child: Text(label, style: TextStyle(color: destructive ? OmniColors.red : null)),
        ),
      ],
    ),
  );
}

class _CardAction extends StatelessWidget {
  const _CardAction({required this.label, required this.onPressed, this.color = OmniColors.cyan});

  final String label;
  final VoidCallback? onPressed;
  final Color color;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 30,
    child: OutlinedButton(
      onPressed: onPressed,
      style: OutlinedButton.styleFrom(
        foregroundColor: color,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        textStyle: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold),
      ),
      child: Text(label),
    ),
  );
}

class _MiniMetric extends StatelessWidget {
  const _MiniMetric({required this.label, required this.value, this.display});

  final String label;
  final double value;
  final String? display;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: const TextStyle(fontSize: 9, fontWeight: FontWeight.bold)),
          Text(display ?? '${value.round()}%', style: const TextStyle(fontSize: 9)),
        ],
      ),
      const SizedBox(height: 3),
      GaugeBar(value: value, color: OmniColors.cyan, height: 4),
    ],
  );
}

class _AuthFailure extends StatelessWidget {
  const _AuthFailure({required this.server, required this.onRetry});

  final Server server;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const Icon(Icons.warning, size: 16, color: OmniColors.red),
      const SizedBox(width: 6),
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Online · SSH authentication failed',
              style: TextStyle(color: OmniColors.red, fontWeight: FontWeight.bold, fontSize: 11),
            ),
            if (server.authError?.isNotEmpty == true)
              Text(
                server.authError!,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                  fontFamily: OmniFonts.mono,
                  fontSize: 10,
                ),
              ),
          ],
        ),
      ),
      _CardAction(label: 'Retry', color: OmniColors.red, onPressed: onRetry),
    ],
  );
}

class _HealthRing extends StatelessWidget {
  const _HealthRing({required this.score});

  final int score;

  @override
  Widget build(BuildContext context) {
    final color = switch (score) {
      >= 90 => OmniColors.green,
      >= 70 => OmniColors.cyan,
      >= 50 => OmniColors.amber,
      _ => OmniColors.red,
    };
    return Semantics(
      label: 'Health score: $score out of 100',
      child: SizedBox.square(
        dimension: 38,
        child: Stack(
          alignment: Alignment.center,
          children: [
            CircularProgressIndicator(
              value: score.clamp(0, 100) / 100,
              strokeWidth: 3,
              color: color,
              backgroundColor: Theme.of(context).colorScheme.outline,
            ),
            Text(
              '$score',
              style: TextStyle(
                color: color,
                fontFamily: OmniFonts.display,
                fontWeight: FontWeight.bold,
                fontSize: 11,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StatusDot extends StatelessWidget {
  const _StatusDot({required this.server});

  final Server server;

  @override
  Widget build(BuildContext context) {
    final color = switch (server) {
      _ when server.authStatus == 'failed' => OmniColors.amber,
      _ when server.status == 'online' => OmniColors.green,
      _ when server.status == 'connecting' => OmniColors.cyan,
      _ => OmniColors.textMuted,
    };
    return Container(
      width: 8,
      height: 8,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.hasServers});

  /// Distinguishes "you have no hosts" from "your filter matched none" — the same blank screen for
  /// both leaves the user thinking their fleet vanished.
  final bool hasServers;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      key: const ValueKey('servers.empty'),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(hasServers ? Icons.search_off : Icons.dns, size: 40, color: OmniColors.textMuted),
            const SizedBox(height: 12),
            Text(
              hasServers ? 'No hosts match your filter' : 'No servers yet',
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}
