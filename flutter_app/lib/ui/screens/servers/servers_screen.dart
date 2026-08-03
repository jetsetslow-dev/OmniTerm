import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../data/app_database.dart';
import '../../../domain/host_display.dart';
import '../../theme/colors.dart';
import '../../theme/typography.dart';
import '../../view_model/servers_view_model.dart';
import '../../widgets/omni_components.dart';
import 'server_form_sheet.dart';
import 'server_form_state.dart';

/// The Servers screen, ported from `ServersMainView` in `ui/AppUi.kt`.
///
/// Every interactive element carries a stable [Key] (`ValueKey('servers.…')`). That is a
/// requirement, not a style choice: the Patrol suite has to target these on both platforms, and
/// Flutter paints its own pixels so there is no native view tree to fall back on. Adding the keys
/// while a screen is written costs nothing; retrofitting them across 36k LOC does not.
class ServersScreen extends StatelessWidget {
  const ServersScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final vm = context.watch<ServersViewModel>();
    final filtered = vm.filteredServers;

    return Stack(
      children: [
        Column(
          children: [
            _SummaryBanner(servers: vm.servers),
            _SearchRow(vm: vm),
            _GroupChips(vm: vm),
            Expanded(
              child: filtered.isEmpty
                  ? _EmptyState(hasServers: vm.servers.isNotEmpty)
                  : ListView.builder(
                      key: const ValueKey('servers.list'),
                      padding: const EdgeInsets.fromLTRB(10, 0, 10, 88),
                      itemCount: filtered.length,
                      itemBuilder: (context, index) =>
                          _ServerCard(server: filtered[index], vm: vm),
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
            onPressed: () => openServerForm(context, vm, mode: ServerFormMode.add),
            child: const Icon(Icons.add),
          ),
        ),
      ],
    );
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
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => ServerFormSheet(
      mode: mode,
      source: source,
      existingServers: vm.servers,
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
          Expanded(child: OmniStatBox(value: '${servers.length}', label: 'Total')),
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
  late final TextEditingController _controller =
      TextEditingController(text: widget.vm.serverSearchText);

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

class _ServerCard extends StatelessWidget {
  const _ServerCard({required this.server, required this.vm});

  final Server server;
  final ServersViewModel vm;

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
    final selected = vm.selectedServerId == server.id;
    final ticked = vm.selectedServerIdsForBulk.contains(server.id);

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: OmniCard(
        key: ValueKey('servers.card.${server.id}'),
        leftAccent: accent,
        semanticLabel: '${server.name}, ${_statusLabel(server)}',
        onTap: () => vm.isMultiSelectMode
            ? vm.toggleBulkSelection(server.id)
            : vm.selectedServerId = server.id,
        onLongPress: vm.isMultiSelectMode
            ? null
            : () => openServerForm(context, vm,
                mode: ServerFormMode.edit, source: server),
        child: Row(
          children: [
            if (vm.isMultiSelectMode)
              Checkbox(
                key: ValueKey('servers.card.${server.id}.check'),
                value: ticked,
                onChanged: (_) => vm.toggleBulkSelection(server.id),
              ),
            _StatusDot(server: server),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    display.name(server),
                    style: TextStyle(
                      color: scheme.onSurface,
                      fontWeight: FontWeight.bold,
                      fontSize: 14,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    display.userAtHost(server),
                    style: TextStyle(
                      color: scheme.onSurfaceVariant,
                      fontFamily: OmniFonts.mono,
                      fontSize: 11,
                    ),
                  ),
                ],
              ),
            ),
            if (selected && !vm.isMultiSelectMode)
              const Icon(Icons.check_circle, size: 18, color: OmniColors.cyan),
          ],
        ),
      ),
    );
  }

  String _statusLabel(Server server) {
    // Auth state is reported separately from reachability: a host can answer on the port and still
    // reject the credentials, and calling that "online" would send the user hunting the wrong fault.
    if (server.authStatus == 'failed') return 'authentication failed';
    return server.status;
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
