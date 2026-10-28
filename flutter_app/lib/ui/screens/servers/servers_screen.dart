import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../data/app_database.dart';
import '../../../data/remote_models.dart';
import '../../../domain/host_display.dart';
import '../../../domain/external_ui_requests.dart';
import '../../../domain/host_list.dart';
import '../../../domain/measurement_units.dart';
import '../../../domain/session_age.dart';
import '../../../l10n/app_localizations.dart';
import '../../../platform/distribution.dart';
import '../../../platform/license_controller.dart';
import '../../../platform/shortcut_helper.dart';
import '../../navigation.dart';
import '../../theme/colors.dart';
import '../../theme/typography.dart';
import '../../view_model/servers_view_model.dart';
import '../../view_model/host_status_probe.dart';
import '../../view_model/network_view_model.dart';
import '../../view_model/sftp_view_model.dart';
import '../../view_model/shell_view_model.dart';
import '../../view_model/telemetry_poller.dart';
import '../../widgets/copy_with_confirmation.dart';
import '../../widgets/health_breakdown_dialog.dart';
import '../../widgets/omni_components.dart';
import '../../widgets/omni_confirm.dart';
import '../../widgets/license_gate.dart';
import '../../widgets/wake_on_lan.dart';
import '../monitor/system_specs_view.dart';
import 'attach_tmux_dialog.dart';
import 'host_check_dialog.dart';
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
    this.network,
  });

  final LicenseController? licenseController;
  final ExternalUiRequests? externalUiRequests;
  final NavigationController? navigation;
  final TelemetryPoller? telemetry;
  final HostStatusProbe? hostProbe;
  final ShellViewModel? shell;
  final SftpViewModel? sftp;
  final ShortcutHelper? shortcuts;

  /// Pings and traces a host from this device, and wakes an offline one.
  final NetworkViewModel? network;

  @override
  Widget build(BuildContext context) {
    final vm = context.watch<ServersViewModel>();
    final filtered = sortHosts(vm.filteredServers, vm.hostSort, _currentHealthScore);
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

  /// Kotlin's `currentHealthScore`: a host without current metrics has no score (-1).
  int _currentHealthScore(Server server) =>
      telemetry?.metricsForServer(server.id) == null ? -1 : server.healthScore;

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
          _SearchRow(
            vm: vm,
            telemetry: telemetry,
            // Kotlin disables "+" at the free limit; unlocking lives in the app-wide plan banner.
            onAdd: atLimit ? null : () => openServerForm(context, vm, mode: ServerFormMode.add),
          ),
          if (atLimit)
            Padding(
              key: const ValueKey('servers.limit'),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              child: Text(
                'Free Play Store build is limited to 1 saved host. Unlock OmniTerm to add more.',
                style: composeBody(
                  fontSize: 12,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          _GroupChips(vm: vm),
          if (vm.isMultiSelectMode) _BulkActions(vm: vm),
          Expanded(
            child: filtered.isEmpty
                ? _EmptyState(
                    hasServers: vm.servers.isNotEmpty,
                    atLimit: atLimit,
                    onAdd: () => openServerForm(context, vm, mode: ServerFormMode.add),
                  )
                : ListView.builder(
                    key: const ValueKey('servers.list'),
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    itemCount: filtered.length,
                    itemBuilder: (context, index) => _ServerCard(
                      server: filtered[index],
                      vm: vm,
                      navigation: navigation,
                      metrics: telemetry?.metricsForServer(filtered[index].id),
                      telemetry: telemetry,
                      hostProbe: hostProbe,
                      shell: shell,
                      sftp: sftp,
                      shortcuts: shortcuts,
                      network: network,
                    ),
                  ),
          ),
        ],
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
  final profiles = await vm.savedProfiles();
  if (!context.mounted) return;
  // Captured now: the sheet has closed by the time an edit's notice is ready to show.
  final messenger = ScaffoldMessenger.maybeOf(context);
  // Kotlin's free-tier credential limit (profiles + keys) also gates "Save securely to Credential
  // Store". Absent in tests and source builds, where there is no limit.
  bool credentialLimitReached() {
    LicenseController? license;
    try {
      license = context.read<LicenseController>();
    } on ProviderNotFoundException {
      license = null;
    }
    return isPlayStoreDistribution &&
        !(license?.state.value.unlocked ?? true) &&
        profiles.length + aliases.length >= 1;
  }

  return showDialog<void>(
    context: context,
    builder: (_) => ServerFormSheet(
      mode: mode,
      source: source,
      prefillHost: prefillHost,
      prefillPort: prefillPort,
      suggestedName: suggestedName,
      existingServers: vm.servers,
      savedKeyAliases: aliases,
      savedProfiles: profiles,
      onSave: (server, {createProfile = false}) async {
        if (mode != ServerFormMode.edit) {
          await vm.saveServer(
            server,
            createProfile: createProfile,
            credentialLimitReached: credentialLimitReached(),
          );
          return;
        }
        final notice = await vm.updateServer(server);
        if (notice != null) messenger?.showSnackBar(SnackBar(content: Text(notice)));
      },
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
  const _SearchRow({required this.vm, required this.onAdd, this.telemetry});

  final ServersViewModel vm;
  final TelemetryPoller? telemetry;

  /// Null at the free host limit, which disables "+" as Kotlin does.
  final VoidCallback? onAdd;

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
                hintText: 'Hostname or IP',
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
          // Kotlin keeps the auto-refresh countdown inline in this toolbar.
          RefreshCountdown(
            key: const ValueKey('servers.refreshCountdown'),
            nextAt: widget.telemetry?.nextCycleAt,
            interval: widget.telemetry?.effectiveInterval ?? const Duration(seconds: 15),
            size: 26,
          ),
          const SizedBox(width: 4),
          _SortButton(vm: vm),
          IconButton(
            key: const ValueKey('servers.multiSelect.toggle'),
            tooltip: 'Multi-select',
            onPressed: () => vm.isMultiSelectMode = !vm.isMultiSelectMode,
            icon: Icon(
              vm.isMultiSelectMode ? Icons.checklist : Icons.checklist_outlined,
              color: vm.isMultiSelectMode
                  ? Theme.of(context).colorScheme.primary
                  // Compose's Color.Gray.
                  : const Color(0xFF888888),
            ),
          ),
          const SizedBox(width: 4),
          // Add lives at the top so it never overlaps cards in a long host list.
          IconButton.filled(
            key: const ValueKey('servers.add'),
            tooltip: 'Add server',
            onPressed: widget.onAdd,
            icon: const Icon(Icons.add),
          ),
        ],
      ),
    );
  }
}

/// Kotlin's sort control: grey while the list is in name order, tinted once another order is picked,
/// with a tick beside the current one.
class _SortButton extends StatelessWidget {
  const _SortButton({required this.vm});

  final ServersViewModel vm;

  @override
  Widget build(BuildContext context) => PopupMenuButton<HostSort>(
    key: const ValueKey('servers.sort'),
    tooltip: 'Sort hosts',
    icon: Icon(
      Icons.sort,
      color: vm.hostSort != HostSort.name
          ? Theme.of(context).colorScheme.primary
          // Compose's Color.Gray.
          : const Color(0xFF888888),
    ),
    onSelected: vm.updateHostSort,
    itemBuilder: (_) => [
      for (final sort in HostSort.values)
        PopupMenuItem(
          key: ValueKey('servers.sort.${sort.settingValue}'),
          value: sort,
          child: Row(
            children: [
              SizedBox.square(
                dimension: 24,
                child: sort == vm.hostSort ? const Icon(Icons.check) : null,
              ),
              const SizedBox(width: 12),
              Flexible(child: Text(sort.label)),
            ],
          ),
        ),
    ],
  );
}

class _GroupChips extends StatelessWidget {
  const _GroupChips({required this.vm});

  final ServersViewModel vm;

  @override
  Widget build(BuildContext context) {
    // Kotlin always shows the row, "All" first.
    final chips = vm.groupChips;

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
        Expanded(
          child: Text(
            AppLocalizations.of(context).serversSelected(vm.selectedServerIdsForBulk.length),
            // Kotlin: FontWeight.Medium.
            style: composeBody(fontWeight: FontWeight.w500),
          ),
        ),
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
    final l10n = AppLocalizations.of(context);
    final ids = vm.selectedServerIdsForBulk.toSet();
    final endTmux = await _confirmHostDelete(
      context,
      vm,
      ids,
      title: ids.length == 1 ? l10n.deleteOneHost : l10n.deleteNHosts(ids.length),
      message: l10n.removeTheseHostConnectionsAndTheir,
      optionLabel: (count) => count == 1
          ? l10n.alsoEndTheTmuxSessionOnTheRemovedHosts
          : l10n.alsoEndTheTmuxSessionsOnTheRemovedHosts(count),
      keyPrefix: 'servers.bulk.delete',
    );
    if (endTmux != null) await vm.deleteSelectedServers(endTmuxSessions: endTmux);
  }
}

/// Asks before deleting the hosts of [ids], as Kotlin does: the option to end their tmux sessions
/// is offered only when there are some, since the dialog otherwise promises the remote machines are
/// left alone. Null when cancelled; otherwise whether to end them.
Future<bool?> _confirmHostDelete(
  BuildContext context,
  ServersViewModel vm,
  Set<int> ids, {
  required String title,
  required String message,
  required String Function(int count) optionLabel,
  required String keyPrefix,
}) async {
  final confirmLabel = AppLocalizations.of(context).delete;
  final tmuxCount = vm.tmuxSessionCount(ids);
  if (tmuxCount == 0) {
    final confirmed = await showOmniConfirm(
      context,
      title: title,
      message: message,
      confirmLabel: confirmLabel,
      destructive: true,
      keyPrefix: keyPrefix,
    );
    return confirmed ? false : null;
  }
  return showOmniConfirmWithOption(
    context,
    title: title,
    message: message,
    optionLabel: optionLabel(tmuxCount),
    confirmLabel: confirmLabel,
    keyPrefix: keyPrefix,
  );
}

class _ServerCard extends StatelessWidget {
  const _ServerCard({
    required this.server,
    required this.vm,
    this.navigation,
    this.metrics,
    this.telemetry,
    this.hostProbe,
    this.shell,
    this.sftp,
    this.shortcuts,
    this.network,
  });

  final Server server;
  final ServersViewModel vm;
  final NavigationController? navigation;
  final HostMetrics? metrics;
  final TelemetryPoller? telemetry;
  final HostStatusProbe? hostProbe;
  final ShellViewModel? shell;
  final SftpViewModel? sftp;
  final ShortcutHelper? shortcuts;
  final NetworkViewModel? network;

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
    // Kotlin's `probedServerIds`: the stored status is only `offline` because nothing has looked yet,
    // so an unprobed host reads as being checked rather than as a failed check.
    final probed = hostProbe?.hasProbed(server.id) ?? true;
    final checking = server.status == 'connecting' || !probed;

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
                _StatusDot(server: server, measured: metrics != null, accent: accent),
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
                      : checking
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
                  child: ScoreRing(
                    score: server.status == 'online' && metrics != null ? server.healthScore : -1,
                    size: 38,
                  ),
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
              // Kotlin draws no metric row until there are metrics to put in it.
              if (metrics == null) ...[
                Text(
                  vm.metricsErrorFor(server.id) ?? 'Waiting for verified metrics…',
                  style: const TextStyle(color: OmniColors.textMuted, fontSize: 12),
                ),
                _MetricRetryButton(server: server, telemetry: telemetry, probe: hostProbe),
              ] else
                Row(
                  children: [
                    Expanded(
                      child: _MiniMetric(label: 'CPU', value: metrics?.cpuPercent),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _MiniMetric(label: 'RAM', value: metrics?.memPercent),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _MiniMetric(label: 'DISK', value: metrics?.diskPercent),
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
                      Icon(
                        Icons.circle,
                        size: 6,
                        color: metrics == null ? OmniColors.textMuted : OmniColors.green,
                      ),
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
                            color: metrics == null
                                ? OmniColors.textMuted
                                : server.authStatus == 'ok'
                                ? OmniColors.green
                                : OmniColors.amber,
                            fontFamily: OmniFonts.mono,
                            fontSize: 10,
                          ),
                        ),
                      ),
                    ],
                  ),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    spacing: 6,
                    children: [
                      OmniButton(
                        key: ValueKey('servers.card.${server.id}.ssh'),
                        label: 'SSH',
                        color: accent,
                        small: true,
                        onPressed: shell == null ? null : () => _connect(context),
                      ),
                      OmniButton(
                        key: ValueKey('servers.card.${server.id}.sftp'),
                        label: 'SFTP',
                        color: accent,
                        small: true,
                        onPressed: sftp == null ? null : _openSftp,
                      ),
                      OmniButton(
                        key: ValueKey('servers.card.${server.id}.docker'),
                        label: 'DOCKER',
                        color: accent,
                        small: true,
                        onPressed: () => _navigate(Screen.infra),
                      ),
                      if (network != null) _pingButton(context, accent),
                    ],
                  ),
                ],
              ),
            ] else if (checking)
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
                          'AUTOMATIC SSH CHECK FAILED',
                          style: TextStyle(
                            color: OmniColors.red,
                            fontWeight: FontWeight.bold,
                            fontSize: 11,
                          ),
                        ),
                        Text(
                          'No response through the configured SSH route to '
                          '${display.host(server)}:${server.port}',
                          style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 10),
                        ),
                        if (vm.lastSeenAt(server.id) case final seenAt?)
                          Text(
                            key: ValueKey('servers.card.${server.id}.lastSeen'),
                            DateTime.now().millisecondsSinceEpoch - seenAt < 60000
                                ? 'Last seen just now'
                                : 'Last seen '
                                      '${formatSessionAge(DateTime.fromMillisecondsSinceEpoch(seenAt))}'
                                      ' ago',
                            style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 10),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 6),
                  _offlineActions(context, accent),
                ],
              ),
          ],
        ),
      ),
    );
  }

  OmniButton _pingButton(BuildContext context, Color accent) => OmniButton(
    key: ValueKey('servers.card.${server.id}.ping'),
    label: 'PING',
    color: accent,
    small: true,
    onPressed: () => showHostCheckDialog(context, network!, server, HostCheck.ping),
  );

  /// WAKE (when a Wake-on-LAN target has this host's address), SSH anyway, PING and Retry, as
  /// Kotlin's offline card. They keep their natural width beside the explanation, and wrap rather
  /// than overflow when large text makes them wider than the card allows.
  Widget _offlineActions(BuildContext context, Color accent) {
    Widget buttons() {
      final wake = network == null ? null : wolTargetFor(server, network!.wolTargets);
      return Wrap(
        alignment: WrapAlignment.end,
        spacing: 6,
        runSpacing: 6,
        children: [
          if (wake != null)
            OmniButton(
              key: ValueKey('servers.card.${server.id}.wake'),
              label: 'WAKE',
              color: OmniColors.green,
              small: true,
              onPressed: () => confirmAndWake(context, network!, wake),
            ),
          OmniButton(
            key: ValueKey('servers.card.${server.id}.sshAnyway'),
            label: 'SSH anyway',
            color: accent,
            small: true,
            onPressed: shell == null ? null : () => _connect(context),
          ),
          if (network != null) _pingButton(context, accent),
          OmniButton(
            key: ValueKey('servers.card.${server.id}.retry'),
            label: 'Retry',
            color: OmniColors.red,
            small: true,
            onPressed: hostProbe == null ? null : () => hostProbe!.probeOne(server),
          ),
        ],
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) => ConstrainedBox(
        constraints: BoxConstraints(maxWidth: constraints.maxWidth * 0.7),
        // Wake targets can be added in Tools while this card is showing.
        child: network == null
            ? buttons()
            : ListenableBuilder(listenable: network!, builder: (_, _) => buttons()),
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
    // The offline confirmation and connection progress must appear immediately after the tap.
    // Android's launcher shortcut channel can complete later (especially on a fresh emulator),
    // so it must not hold the SSH action behind shortcut bookkeeping.
    await shell?.connect(server, controlMode: shell!.useControlMode);
    await shortcuts?.pushServer(server);
    await shortcuts?.reportServerUsed(server.id);
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
          _DialogAction(value: 'copySsh', icon: Icons.content_paste, label: 'Copy SSH command'),
          if (shell != null)
            _DialogAction(value: 'shell', icon: Icons.terminal, label: 'Open terminal console'),
          // A Windows host has no tmux: absent rather than shown and refused.
          if (shell != null && vm.hasKnownUnixShell(server))
            _DialogAction(
              value: 'attachTmux',
              icon: Icons.terminal,
              label: 'Attach existing tmux…',
              enabled: server.status == 'online',
            ),
          if (network != null) ...[
            _DialogAction(value: 'ping', icon: Icons.network_check, label: 'Ping from this device'),
            _DialogAction(
              value: 'traceroute',
              icon: Icons.route,
              label: 'Traceroute from this device',
            ),
          ],
          // Read over SSH, so only while the host answers.
          _DialogAction(
            value: 'specs',
            icon: Icons.developer_board,
            label: 'System specs',
            enabled: server.status == 'online',
          ),
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
      case 'copySsh':
        final command = await vm.sshCommand(server);
        if (context.mounted) await copyWithConfirmation(context, command);
      case 'shell':
        await _connect(context);
      case 'attachTmux':
        await showAttachTmuxDialog(context, shell!, server, navigation: navigation);
      case 'ping':
        await showHostCheckDialog(context, network!, server, HostCheck.ping);
      case 'traceroute':
        await showHostCheckDialog(context, network!, server, HostCheck.traceroute);
      case 'specs':
        await showSystemSpecsDialog(context, server);
      case 'monitor':
        _navigate(Screen.monitor);
      case 'infra':
        _navigate(Screen.infra);
      case 'delete':
        await _confirmDelete(context);
    }
  }

  Future<void> _confirmDelete(BuildContext context) async {
    final l10n = AppLocalizations.of(context);
    final endTmux = await _confirmHostDelete(
      context,
      vm,
      {server.id},
      title: l10n.delete2(server.name),
      message: l10n.removeThisHostConnectionAndIts,
      optionLabel: (count) => count == 1
          ? l10n.alsoEndItsTmuxSessionOnTheServer
          : l10n.alsoEndItsTmuxSessionsOnTheServer(count),
      keyPrefix: 'servers.card.${server.id}.delete',
    );
    if (endTmux != null) await vm.deleteServer(server.id, endTmuxSessions: endTmux);
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
    this.enabled = true,
  });

  final String value;
  final IconData icon;
  final String label;
  final bool destructive;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final color = !enabled
        ? Theme.of(context).disabledColor
        : destructive
        ? OmniColors.red
        : null;
    return SimpleDialogOption(
      key: ValueKey('servers.action.$value'),
      onPressed: enabled ? () => Navigator.pop(context, value) : null,
      child: Row(
        children: [
          Icon(icon, color: color),
          const SizedBox(width: 10),
          Expanded(
            child: Text(label, style: TextStyle(color: color)),
          ),
        ],
      ),
    );
  }
}

class _MetricRetryButton extends StatefulWidget {
  const _MetricRetryButton({required this.server, this.telemetry, this.probe});
  final Server server;
  final TelemetryPoller? telemetry;
  final HostStatusProbe? probe;
  @override
  State<_MetricRetryButton> createState() => _MetricRetryButtonState();
}

class _MetricRetryButtonState extends State<_MetricRetryButton> {
  bool _busy = false;
  Future<void> _refresh() async {
    if (_busy) return;
    setState(() => _busy = true);
    String? failure;
    try {
      await widget.probe?.probeOne(widget.server);
      failure =
          await widget.telemetry?.pollOne(widget.server) ??
          (widget.telemetry == null ? 'Metrics are unavailable in this build.' : null);
    } catch (error) {
      failure = '$error';
    } finally {
      if (mounted) {
        setState(() => _busy = false);
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(failure ?? 'Metrics refreshed.')));
      }
    }
  }

  @override
  Widget build(BuildContext context) => TextButton.icon(
    onPressed: _busy ? null : _refresh,
    icon: _busy
        ? const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2))
        : const Icon(Icons.refresh, size: 16),
    label: Text(_busy ? 'Refreshing metrics…' : 'Refresh metrics'),
  );
}

class _MiniMetric extends StatelessWidget {
  const _MiniMetric({required this.label, required this.value, this.display});

  final String label;
  final double? value;
  final String? display;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: const TextStyle(fontSize: 9, fontWeight: FontWeight.bold)),
          Text(
            display ?? (value == null ? '—' : '${value!.round()}%'),
            style: const TextStyle(fontSize: 9),
          ),
        ],
      ),
      const SizedBox(height: 3),
      GaugeBar(
        value: value ?? 0,
        color: value == null ? OmniColors.textMuted : OmniColors.cyan,
        height: 4,
      ),
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
      OmniButton(label: 'Retry', color: OmniColors.red, small: true, onPressed: onRetry),
    ],
  );
}

class _StatusDot extends StatelessWidget {
  const _StatusDot({required this.server, required this.measured, required this.accent});

  final Server server;
  final bool measured;
  final Color accent;

  /// Kotlin's `StatusDot` on the host card: red unless online or connecting; amber while connecting,
  /// muted until live metrics arrive, then the host's identity colour.
  @override
  Widget build(BuildContext context) {
    final color = switch (server.status) {
      'connecting' => OmniColors.amber,
      'online' when !measured => OmniColors.textMuted,
      'online' => accent,
      _ => OmniColors.red,
    };
    return Container(
      width: 8,
      height: 8,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
  }
}

/// Kotlin's empty host list (`ServersScreen` in `ui/AppUi.kt`): a first-run checklist when there
/// are no hosts at all, "No servers found" when a filter matches none, and Add Host Server either
/// way. The two cases differ because the same blank screen for both leaves the user thinking their
/// fleet vanished.
class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.hasServers, required this.onAdd, required this.atLimit});

  final bool hasServers;
  final VoidCallback? onAdd;
  final bool atLimit;

  static const _firstRunSteps = [
    '1.  An SSH server must be running on it (on most Linux: sudo apt install openssh-server)',
    '2.  Find its IP address or hostname (e.g. 192.168.1.50)',
    '3.  Have your username and password — or an SSH key — ready',
    "4.  On first connect, OmniTerm shows the server's key fingerprint so you can verify it",
  ];

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    return Center(
      key: const ValueKey('servers.empty'),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.dns, size: 64, color: Color(0xFFCCCCCC)),
            const SizedBox(height: 8),
            if (hasServers)
              Text(l10n.noServersFound, style: composeBody(color: muted))
            else ...[
              // True first run: what a beginner needs before tapping Add.
              Text(l10n.connectYourFirstServer, style: composeBody(fontWeight: FontWeight.bold)),
              Padding(
                padding: const EdgeInsets.fromLTRB(32, 8, 32, 0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final step in _firstRunSteps)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 2),
                        child: Text(step, style: composeBody(fontSize: 12, color: muted)),
                      ),
                  ],
                ),
              ),
            ],
            Padding(
              padding: const EdgeInsets.only(top: 16),
              child: FilledButton(
                key: const ValueKey('servers.empty.add'),
                onPressed: atLimit ? null : onAdd,
                child: Text(l10n.addHostServer),
              ),
            ),
            if (atLimit)
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 8, 24, 0),
                child: Text(
                  l10n.freePlayStoreBuildIsLimited,
                  style: composeBody(fontSize: 12, color: muted),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
