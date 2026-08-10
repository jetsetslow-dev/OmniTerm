import 'dart:async';

import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../../data/app_database.dart';
import '../../../data/network/network_probe.dart';
import '../../../domain/host_display.dart';
import '../../../domain/external_ui_requests.dart';
import '../../../domain/network_tools.dart';
import '../../../domain/tunnel_form.dart';
import '../../view_model/app_state.dart';
import '../../theme/colors.dart';
import '../../theme/typography.dart';
import '../../../domain/whois.dart';
import '../../view_model/network_view_model.dart';
import '../../widgets/omni_components.dart';
import '../../navigation.dart';

/// The Network tool, ported from `NetworkToolView` in `ui/ToolsScreen.kt`.
///
/// Everything here runs from the **device**, not over SSH: these are the tools you reach for when a
/// host is not answering and you cannot get a shell on it.
class NetworkScreen extends StatefulWidget {
  const NetworkScreen({super.key});

  @override
  State<NetworkScreen> createState() => _NetworkScreenState();
}

class _NetworkScreenState extends State<NetworkScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) context.read<NetworkViewModel>().start();
    });
  }

  static const _labels = {
    NetworkTab.hostScan: 'Host scan',
    NetworkTab.wakeOnLan: 'Wake-on-LAN',
    NetworkTab.ping: 'Ping',
    NetworkTab.traceroute: 'Traceroute',
    NetworkTab.portScan: 'Port scan',
    NetworkTab.dnsLookup: 'DNS',
    NetworkTab.whois: 'WHOIS',
    NetworkTab.speedTest: 'Speed test',
    NetworkTab.tunnels: 'Tunnels',
  };

  @override
  Widget build(BuildContext context) {
    final vm = context.watch<NetworkViewModel>();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          height: 44,
          child: ListView(
            key: const ValueKey('network.tabs'),
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            children: [
              for (final tab in NetworkTab.values)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: Center(
                    child: ChoiceChip(
                      key: ValueKey('network.tab.${tab.name}'),
                      label: Text(_labels[tab]!, style: const TextStyle(fontSize: 12)),
                      selected: vm.activeTab == tab,
                      onSelected: (_) => vm.activeTab = tab,
                    ),
                  ),
                ),
            ],
          ),
        ),
        if (vm.error != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
            child: OmniCard(
              key: const ValueKey('network.error'),
              leftAccent: OmniColors.red,
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      vm.error!,
                      style: const TextStyle(fontSize: 12, color: OmniColors.red),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Dismiss',
                    key: const ValueKey('network.error.dismiss'),
                    icon: const Icon(Icons.close, size: 16),
                    onPressed: vm.dismissError,
                  ),
                ],
              ),
            ),
          ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: switch (vm.activeTab) {
              NetworkTab.hostScan => _HostScanTab(vm: vm),
              NetworkTab.wakeOnLan => _WolTab(vm: vm),
              NetworkTab.ping => _PingTab(vm: vm),
              NetworkTab.traceroute => _TracerouteTab(vm: vm),
              NetworkTab.portScan => _PortScanTab(vm: vm),
              NetworkTab.dnsLookup => _DnsTab(vm: vm),
              NetworkTab.whois => _WhoisTab(vm: vm),
              NetworkTab.speedTest => _SpeedTestTab(vm: vm),
              NetworkTab.tunnels => _TunnelsTab(vm: vm),
            },
          ),
        ),
      ],
    );
  }
}

class _SpeedTestTab extends StatelessWidget {
  const _SpeedTestTab({required this.vm});

  final NetworkViewModel vm;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final selected = NetworkViewModel.speedTestServers
        .where((server) => server.$2 == vm.speedTestUrl)
        .firstOrNull;
    return ListView(
      key: const ValueKey('network.speedTest'),
      children: [
        Text(
          "Measures this device's download throughput. The test stops after 15 seconds.",
          style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
        ),
        const SizedBox(height: 12),
        DropdownButtonFormField<String>(
          key: const ValueKey('network.speedTest.server'),
          isExpanded: true,
          initialValue: selected?.$2,
          decoration: omniInputDecoration(context, labelText: 'Test server'),
          hint: const Text('Custom URL'),
          items: [
            for (final server in NetworkViewModel.speedTestServers)
              DropdownMenuItem(
                value: server.$2,
                child: Text(server.$1, maxLines: 1, overflow: TextOverflow.ellipsis),
              ),
          ],
          onChanged: vm.speedTestRunning
              ? null
              : (value) => vm.speedTestUrl = value ?? vm.speedTestUrl,
        ),
        const SizedBox(height: 10),
        _ToolField(
          fieldKey: 'network.speedTest.url',
          label: 'Download URL',
          initial: vm.speedTestUrl,
          mono: true,
          onChanged: (value) => vm.speedTestUrl = value,
        ),
        const SizedBox(height: 12),
        OmniCard(
          leftAccent: OmniColors.cyan,
          child: Column(
            children: [
              Text(
                vm.speedTestMbps?.toStringAsFixed(1) ?? '—',
                key: const ValueKey('network.speedTest.mbps'),
                style: TextStyle(
                  fontSize: 44,
                  fontWeight: FontWeight.bold,
                  fontFamily: OmniFonts.mono,
                  color: vm.speedTestRunning ? OmniColors.cyan : OmniColors.green,
                ),
              ),
              Text('Mbps', style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant)),
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  _SpeedMetric(value: _formatBytes(vm.speedTestBytes), label: 'Downloaded'),
                  if (vm.speedTestLatency != null) ...[
                    const SizedBox(width: 28),
                    _SpeedMetric(
                      value: '${vm.speedTestLatency!.inMilliseconds} ms',
                      label: 'Time to first byte',
                    ),
                  ],
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        FilledButton(
          key: const ValueKey('network.speedTest.run'),
          style: vm.speedTestRunning
              ? FilledButton.styleFrom(backgroundColor: OmniColors.amber)
              : null,
          onPressed: vm.speedTestUrl.trim().isEmpty
              ? null
              : vm.speedTestRunning
              ? vm.cancelSpeedTest
              : vm.runSpeedTest,
          child: Text(vm.speedTestRunning ? 'Stop' : 'Start speed test'),
        ),
        if (vm.speedTestError != null) ...[
          const SizedBox(height: 10),
          Text(
            vm.speedTestError!,
            key: const ValueKey('network.speedTest.error'),
            style: const TextStyle(color: OmniColors.red, fontFamily: OmniFonts.mono, fontSize: 13),
          ),
        ],
      ],
    );
  }
}

class _SpeedMetric extends StatelessWidget {
  const _SpeedMetric({required this.value, required this.label});

  final String value;
  final String label;

  @override
  Widget build(BuildContext context) => Column(
    children: [
      Text(
        value,
        style: const TextStyle(
          fontSize: 14,
          fontFamily: OmniFonts.mono,
          fontWeight: FontWeight.bold,
        ),
      ),
      Text(
        label,
        style: TextStyle(fontSize: 10, color: Theme.of(context).colorScheme.onSurfaceVariant),
      ),
    ],
  );
}

String _formatBytes(int bytes) {
  if (bytes >= 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }
  if (bytes >= 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  if (bytes >= 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  return '$bytes B';
}

/// A labelled text field that keeps its own controller.
class _ToolField extends StatefulWidget {
  const _ToolField({
    required this.fieldKey,
    required this.label,
    required this.initial,
    required this.onChanged,
    this.hint,
    this.mono = false,
  });

  final String fieldKey;
  final String label;
  final String initial;
  final ValueChanged<String> onChanged;
  final String? hint;
  final bool mono;

  @override
  State<_ToolField> createState() => _ToolFieldState();
}

class _ToolFieldState extends State<_ToolField> {
  late final _controller = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(_ToolField old) {
    super.didUpdateWidget(old);
    // Another tab can fill this field (a scanned host sent to Ping), and the controller would
    // otherwise keep showing the old text.
    if (widget.initial != _controller.text && widget.initial != old.initial) {
      _controller.text = widget.initial;
    }
  }

  @override
  Widget build(BuildContext context) {
    return TextField(
      key: ValueKey(widget.fieldKey),
      controller: _controller,
      onChanged: widget.onChanged,
      style: widget.mono ? const TextStyle(fontFamily: OmniFonts.mono, fontSize: 13) : null,
      decoration: omniInputDecoration(context, labelText: widget.label, hintText: widget.hint),
    );
  }
}

class _HostScanTab extends StatelessWidget {
  const _HostScanTab({required this.vm});

  final NetworkViewModel vm;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: _ToolField(
                fieldKey: 'network.scan.subnet',
                label: 'Subnet',
                hint: '192.168.1',
                initial: vm.subnetPrefix,
                mono: true,
                onChanged: (v) => vm.subnetPrefix = v,
              ),
            ),
            const SizedBox(width: 8),
            FilledButton(
              key: const ValueKey('network.scan.run'),
              onPressed: vm.scanning ? null : vm.scanSubnet,
              child: Text(vm.scanning ? 'Scanning…' : 'Scan'),
            ),
          ],
        ),
        if (vm.scanning) ...[
          const SizedBox(height: 8),
          LinearProgressIndicator(value: vm.scanProgress, minHeight: 3),
        ],
        const SizedBox(height: 8),
        Expanded(
          child: vm.scanResults.isEmpty
              ? Center(
                  key: const ValueKey('network.scan.empty'),
                  child: Text(
                    vm.scanning
                        ? 'Sweeping ${vm.subnetPrefix}.1–254…'
                        // Naming the ports makes the result interpretable: a host with none of them
                        // open is not necessarily down.
                        : 'Sweeps the subnet for hosts answering on 22, 80, 443, 445, 3389, 5900 '
                              'or 8080.',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                  ),
                )
              : ListView.separated(
                  key: const ValueKey('network.scan.list'),
                  itemCount: vm.scanResults.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 6),
                  itemBuilder: (context, index) {
                    final host = vm.scanResults[index];
                    return OmniCard(
                      key: ValueKey('network.scan.${host.address}'),
                      leftAccent: OmniColors.green,
                      onTap: () => _openHostActions(context, vm, host),
                      child: Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  host.hostname ?? host.address,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.bold,
                                    fontSize: 13,
                                    fontFamily: OmniFonts.mono,
                                  ),
                                ),
                                Text(
                                  [
                                    if (host.hostname != null) host.address,
                                    if (host.macAddress.isNotEmpty)
                                      host.vendor.isEmpty
                                          ? host.macAddress
                                          : '${host.macAddress} · ${host.vendor}',
                                    host.openPorts.map((p) => portLabel(p) ?? '$p').join(', '),
                                  ].join(' · '),
                                  style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
                                ),
                              ],
                            ),
                          ),
                          if (host.latency != null)
                            Text(
                              '${host.latency!.inMilliseconds} ms',
                              style: TextStyle(
                                fontSize: 11,
                                fontFamily: OmniFonts.mono,
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                        ],
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

Future<void> _openHostActions(BuildContext context, NetworkViewModel vm, ScannedHost host) async {
  // A scan result is not yet bound to any tool — the user has just found a device. So the sheet
  // offers the tools that take an address rather than guessing which one was meant.
  final app = context.read<AppState>();
  final saved = app.servers.where((server) => server.host == host.address).firstOrNull;
  final action = await showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (sheetContext) => SafeArea(
      child: ListView(
        shrinkWrap: true,
        padding: EdgeInsets.only(bottom: MediaQuery.viewPaddingOf(sheetContext).bottom),
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              host.hostname ?? host.address,
              style: const TextStyle(fontFamily: OmniFonts.mono),
            ),
          ),
          if (saved != null)
            ListTile(
              title: Text('Already saved as “${saved.name}”'),
              subtitle: Text(host.address),
              enabled: false,
            )
          else
            ListTile(
              key: const ValueKey('network.scan.action.addServer'),
              leading: const Icon(Icons.add_circle_outline),
              title: const Text('Add as OmniTerm host'),
              subtitle: Text(
                host.openPorts.contains(22)
                    ? 'SSH is open on port 22'
                    : 'Open the add-host form for ${host.address}',
              ),
              onTap: () => Navigator.of(sheetContext).pop('addServer'),
            ),
          for (final (value, label) in const [
            ('ping', 'Ping this host'),
            ('traceroute', 'Trace the path to this host'),
            ('portScan', 'Scan its ports'),
            ('dnsLookup', 'Look it up in DNS'),
            ('whois', 'Look up its registration'),
          ])
            ListTile(
              key: ValueKey('network.scan.action.$value'),
              title: Text(label),
              onTap: () => Navigator.of(sheetContext).pop(value),
            ),
          if (host.macAddress.isNotEmpty)
            ListTile(
              key: const ValueKey('network.scan.action.wol'),
              title: const Text('Add as Wake-on-LAN target'),
              subtitle: Text(host.macAddress),
              onTap: () => Navigator.of(sheetContext).pop('wol'),
            ),
          ListTile(
            key: const ValueKey('network.scan.action.copy'),
            title: const Text('Copy IP address'),
            subtitle: Text(host.address),
            onTap: () => Navigator.of(sheetContext).pop('copy'),
          ),
        ],
      ),
    ),
  );
  if (!context.mounted || action == null) return;
  switch (action) {
    case 'addServer':
      context.read<NavigationController>().navigateTo(Screen.servers);
      context.read<ExternalUiRequests>().requestAddServer(
        host: host.address,
        suggestedName: host.hostname ?? host.address,
      );
    case 'ping':
      unawaited(vm.runForHost(host.address, NetworkTab.ping));
    case 'traceroute':
      unawaited(vm.runForHost(host.address, NetworkTab.traceroute));
    case 'portScan':
      unawaited(vm.runForHost(host.address, NetworkTab.portScan, knownOpenPorts: host.openPorts));
    case 'dnsLookup':
      unawaited(vm.runForHost(host.hostname ?? host.address, NetworkTab.dnsLookup));
    case 'whois':
      unawaited(vm.runForHost(host.address, NetworkTab.whois));
    case 'wol':
      vm.activeTab = NetworkTab.wakeOnLan;
      await _openWolEditor(context, vm, scannedHost: host);
    case 'copy':
      await Clipboard.setData(ClipboardData(text: host.address));
  }
}

class _WolTab extends StatelessWidget {
  const _WolTab({required this.vm});

  final NetworkViewModel vm;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        OutlinedButton.icon(
          key: const ValueKey('network.wol.add'),
          icon: const Icon(Icons.add, size: 18),
          label: const Text('New target'),
          onPressed: () => _openWolEditor(context, vm),
        ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          key: const ValueKey('network.wol.scanLan'),
          icon: const Icon(Icons.lan_outlined, size: 18),
          label: const Text('Add from LAN scan'),
          onPressed: () => _pickWolFromScan(context, vm),
        ),
        const SizedBox(height: 8),
        Expanded(
          child: vm.wolTargets.isEmpty
              ? Center(
                  key: const ValueKey('network.wol.empty'),
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      // The prerequisite is not obvious and the feature silently does nothing
                      // without it, so it is said up front rather than left to be discovered.
                      'No targets yet. Wake-on-LAN needs the machine to have it enabled in its '
                      'BIOS and network card.',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                    ),
                  ),
                )
              : ListView.separated(
                  key: const ValueKey('network.wol.list'),
                  itemCount: vm.wolTargets.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 6),
                  itemBuilder: (context, index) {
                    final target = vm.wolTargets[index];
                    return OmniCard(
                      key: ValueKey('network.wol.${target.id}'),
                      leftAccent: OmniColors.green,
                      child: ListenableBuilder(
                        listenable: HostDisplay.instance,
                        builder: (context, _) => Row(
                          children: [
                            _WolStatusDot(vm: vm, target: target),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    target.name,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontWeight: FontWeight.bold,
                                      fontSize: 13,
                                    ),
                                  ),
                                  Text(
                                    [
                                      'MAC: ${HostDisplay.instance.sensitive(target.macAddress)}',
                                      'Port ${target.port}',
                                      if (target.ipAddress.isNotEmpty &&
                                          !HostDisplay.instance.hideSensitiveInfo)
                                        target.ipAddress,
                                    ].join(' · '),
                                    style: TextStyle(
                                      fontSize: 11,
                                      fontFamily: OmniFonts.mono,
                                      color: scheme.onSurfaceVariant,
                                    ),
                                  ),
                                  if (target.notes.isNotEmpty)
                                    Text(
                                      target.notes,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontSize: 11,
                                        fontStyle: FontStyle.italic,
                                        color: scheme.onSurfaceVariant,
                                      ),
                                    ),
                                ],
                              ),
                            ),
                            TextButton(
                              key: ValueKey('network.wol.${target.id}.wake'),
                              onPressed: () => _confirmWake(context, vm, target),
                              child: const Text('Wake', style: TextStyle(fontSize: 12)),
                            ),
                            IconButton(
                              key: ValueKey('network.wol.${target.id}.edit'),
                              tooltip: 'Edit target',
                              icon: const Icon(Icons.edit_outlined, size: 18),
                              onPressed: () => _openWolEditor(context, vm, existing: target),
                            ),
                            IconButton(
                              key: ValueKey('network.wol.${target.id}.delete'),
                              tooltip: 'Delete target',
                              icon: const Icon(
                                Icons.delete_outline,
                                size: 18,
                                color: OmniColors.red,
                              ),
                              onPressed: () => _confirmDeleteWol(context, vm, target),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

Future<void> _confirmWake(BuildContext context, NetworkViewModel vm, WolTarget target) async {
  final accepted = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      key: const ValueKey('network.wol.wake.dialog'),
      title: const Text('Send wake packet?'),
      content: Text(
        'Send a Wake-on-LAN magic packet to “${target.name}” '
        '(${target.macAddress})?',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const ValueKey('network.wol.wake.confirm'),
          onPressed: () => Navigator.pop(dialogContext, true),
          child: const Text('Wake'),
        ),
      ],
    ),
  );
  if (accepted != true) return;
  final message = await vm.wake(target);
  if (context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }
}

Future<void> _pickWolFromScan(BuildContext context, NetworkViewModel vm) async {
  if (vm.scanResults.isEmpty && !vm.scanning) await vm.scanSubnet();
  if (!context.mounted) return;
  final host = await showDialog<ScannedHost>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      key: const ValueKey('network.wol.scan.dialog'),
      title: const Text('Choose a LAN host'),
      content: SizedBox(
        width: 420,
        child: vm.scanning
            ? const Center(child: CircularProgressIndicator())
            : vm.scanResults.where((host) => host.macAddress.isNotEmpty).isEmpty
            ? const Text(
                'No scanned host exposed a MAC address. Android and iOS may restrict access to '
                'the neighbour table; enter the target manually instead.',
              )
            : ListView(
                shrinkWrap: true,
                children: [
                  for (final host in vm.scanResults.where((host) => host.macAddress.isNotEmpty))
                    ListTile(
                      key: ValueKey('network.wol.scan.${host.address}'),
                      title: Text(host.hostname ?? host.address),
                      subtitle: Text('${host.address} · ${host.macAddress}'),
                      onTap: () => Navigator.pop(dialogContext, host),
                    ),
                ],
              ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('Close')),
      ],
    ),
  );
  if (host != null && context.mounted) {
    await _openWolEditor(context, vm, scannedHost: host);
  }
}

Future<void> _confirmDeleteWol(BuildContext context, NetworkViewModel vm, WolTarget target) async {
  final accepted = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      key: const ValueKey('network.wol.delete.dialog'),
      title: Text('Delete ${target.name}?'),
      content: const Text('Remove this saved Wake-on-LAN target?'),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(dialogContext, true),
          child: const Text('Delete'),
        ),
      ],
    ),
  );
  if (accepted == true) await vm.deleteWolTarget(target);
}

Future<void> _openWolEditor(
  BuildContext context,
  NetworkViewModel vm, {
  WolTarget? existing,
  ScannedHost? scannedHost,
}) async {
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => _WolSheet(vm: vm, existing: existing, scannedHost: scannedHost),
  );
}

class _WolStatusDot extends StatefulWidget {
  const _WolStatusDot({required this.vm, required this.target});

  final NetworkViewModel vm;
  final WolTarget target;

  @override
  State<_WolStatusDot> createState() => _WolStatusDotState();
}

class _WolStatusDotState extends State<_WolStatusDot> {
  bool? _online;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    unawaited(_refresh());
    _timer = Timer.periodic(const Duration(seconds: 10), (_) => _refresh());
  }

  Future<void> _refresh() async {
    final value = await widget.vm.wolOnlineStatus(widget.target);
    if (mounted) setState(() => _online = value);
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Container(
    key: ValueKey('network.wol.${widget.target.id}.status'),
    width: 9,
    height: 9,
    margin: const EdgeInsets.only(right: 9),
    decoration: BoxDecoration(
      shape: BoxShape.circle,
      color: switch (_online) {
        true => OmniColors.green,
        false => OmniColors.red,
        null => OmniColors.textMuted,
      },
    ),
  );
}

class _WolSheet extends StatefulWidget {
  const _WolSheet({required this.vm, required this.existing, required this.scannedHost});

  final NetworkViewModel vm;
  final WolTarget? existing;
  final ScannedHost? scannedHost;

  @override
  State<_WolSheet> createState() => _WolSheetState();
}

class _WolSheetState extends State<_WolSheet> {
  late final _name = TextEditingController(
    text:
        widget.existing?.name ?? widget.scannedHost?.hostname ?? widget.scannedHost?.address ?? '',
  );
  late final _mac = TextEditingController(
    text: widget.existing?.macAddress ?? widget.scannedHost?.macAddress ?? '',
  );
  late final _broadcast = TextEditingController(text: widget.existing?.broadcastIp ?? '');
  late final _ip = TextEditingController(
    text: widget.existing?.ipAddress ?? widget.scannedHost?.address ?? '',
  );
  late final _port = TextEditingController(text: '${widget.existing?.port ?? 9}');
  late final _notes = TextEditingController(text: widget.existing?.notes ?? '');
  String? _failure;

  @override
  void dispose() {
    _name.dispose();
    _mac.dispose();
    _broadcast.dispose();
    _ip.dispose();
    _port.dispose();
    _notes.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final failure = await widget.vm.saveWolTarget(
      name: _name.text,
      macAddress: _mac.text,
      existing: widget.existing,
      broadcastIp: _broadcast.text,
      ipAddress: _ip.text,
      port: int.tryParse(_port.text) ?? 0,
      notes: _notes.text,
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
                widget.existing == null ? 'New Wake-on-LAN target' : 'Edit Wake-on-LAN target',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 12),
              TextField(
                key: const ValueKey('network.wol.name'),
                controller: _name,
                decoration: omniInputDecoration(context, labelText: 'Name'),
              ),
              const SizedBox(height: 10),
              TextField(
                key: const ValueKey('network.wol.mac'),
                controller: _mac,
                style: const TextStyle(fontFamily: OmniFonts.mono),
                decoration: omniInputDecoration(
                  context,
                  labelText: 'MAC address',
                  hintText: 'aa:bb:cc:dd:ee:ff',
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                key: const ValueKey('network.wol.broadcast'),
                controller: _broadcast,
                style: const TextStyle(fontFamily: OmniFonts.mono),
                decoration: omniInputDecoration(
                  context,
                  labelText: 'Broadcast address (optional)',
                  helperText: 'Derived from the host address when left empty.',
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                key: const ValueKey('network.wol.ip'),
                controller: _ip,
                style: const TextStyle(fontFamily: OmniFonts.mono),
                decoration: omniInputDecoration(
                  context,
                  labelText: 'Host address (optional)',
                  // Explaining what it buys: a directed broadcast actually reaches a sleeping
                  // machine, where 255.255.255.255 is dropped by many routers.
                  helperText: 'Used to aim the packet at the right subnet broadcast.',
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                key: const ValueKey('network.wol.port'),
                controller: _port,
                keyboardType: TextInputType.number,
                decoration: omniInputDecoration(context, labelText: 'UDP port'),
              ),
              const SizedBox(height: 10),
              TextField(
                key: const ValueKey('network.wol.notes'),
                controller: _notes,
                minLines: 2,
                maxLines: 3,
                decoration: omniInputDecoration(context, labelText: 'Notes'),
              ),
              if (_failure != null)
                Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Text(
                    _failure!,
                    key: const ValueKey('network.wol.error'),
                    style: const TextStyle(color: OmniColors.red, fontSize: 12),
                  ),
                ),
              const SizedBox(height: 14),
              FilledButton(
                key: const ValueKey('network.wol.save'),
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

class _PingTab extends StatelessWidget {
  const _PingTab({required this.vm});

  final NetworkViewModel vm;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: _ToolField(
                fieldKey: 'network.ping.target',
                label: 'Host',
                initial: vm.pingTarget,
                mono: true,
                onChanged: (v) => vm.pingTarget = v,
              ),
            ),
            const SizedBox(width: 8),
            SizedBox(
              width: 82,
              child: _ToolField(
                fieldKey: 'network.ping.count',
                label: 'Tries',
                initial: vm.pingCount.toString(),
                mono: true,
                onChanged: (value) {
                  final parsed = int.tryParse(value.trim());
                  if (parsed != null) vm.pingCount = parsed;
                },
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        SizedBox(
          width: double.infinity,
          child: vm.pinging
              ? FilledButton.tonal(
                  key: const ValueKey('network.ping.stop'),
                  onPressed: vm.stopPing,
                  child: const Text('Stop'),
                )
              : FilledButton(
                  key: const ValueKey('network.ping.run'),
                  onPressed: vm.runPing,
                  child: const Text('Start ping'),
                ),
        ),
        const SizedBox(height: 6),
        Text(
          'ICMP pings are sent from this device. Set tries to 0 to keep pinging until stopped.',
          style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
        ),
        const SizedBox(height: 8),
        Expanded(
          child: SelectionArea(
            child: ListView(
              key: const ValueKey('network.ping.list'),
              children: [
                for (final line in vm.pingLines)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Text(
                      line,
                      style: TextStyle(
                        fontFamily: OmniFonts.mono,
                        fontSize: 11,
                        color:
                            line.toLowerCase().contains('failed') ||
                                line.toLowerCase().contains('unreachable') ||
                                line.contains('100% packet loss')
                            ? OmniColors.red
                            : null,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _TracerouteTab extends StatelessWidget {
  const _TracerouteTab({required this.vm});

  final NetworkViewModel vm;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: _ToolField(
                fieldKey: 'network.traceroute.target',
                label: 'Host',
                initial: vm.tracerouteTarget,
                mono: true,
                onChanged: (v) => vm.tracerouteTarget = v,
              ),
            ),
            const SizedBox(width: 8),
            if (vm.tracerouteRunning)
              FilledButton.tonal(
                key: const ValueKey('network.traceroute.stop'),
                onPressed: vm.stopTraceroute,
                child: const Text('Stop'),
              )
            else
              FilledButton(
                key: const ValueKey('network.traceroute.run'),
                onPressed: vm.runTraceroute,
                child: const Text('Trace'),
              ),
          ],
        ),
        const SizedBox(height: 12),
        Expanded(
          child: ListView(
            key: const ValueKey('network.traceroute.list'),
            children: [
              for (final line in vm.tracerouteLines)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Text(
                    line,
                    style: const TextStyle(fontFamily: OmniFonts.mono, fontSize: 12),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _PortScanTab extends StatelessWidget {
  const _PortScanTab({required this.vm});

  final NetworkViewModel vm;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _ToolField(
          fieldKey: 'network.portScan.target',
          label: 'Host',
          initial: vm.portScanTarget,
          mono: true,
          onChanged: (v) => vm.portScanTarget = v,
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: _ToolField(
                fieldKey: 'network.portScan.ports',
                label: 'Ports',
                hint: '22,80,443 or 8000-8100',
                initial: vm.portSpec,
                mono: true,
                onChanged: (v) => vm.portSpec = v,
              ),
            ),
            const SizedBox(width: 8),
            FilledButton(
              key: const ValueKey('network.portScan.run'),
              onPressed: vm.portScanning ? null : vm.runPortScan,
              child: Text(vm.portScanning ? 'Scanning…' : 'Scan'),
            ),
          ],
        ),
        const SizedBox(height: 8),
        if (vm.portResults.isNotEmpty)
          Text(
            '${vm.openPorts.length} open of ${vm.portResults.length} probed',
            key: const ValueKey('network.portScan.summary'),
            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
          ),
        const SizedBox(height: 6),
        Expanded(
          child: vm.openPorts.isEmpty && !vm.portScanning
              ? Center(
                  key: const ValueKey('network.portScan.empty'),
                  child: Text(
                    vm.portResults.isEmpty
                        ? 'Probes each port with a TCP connect.'
                        : 'No open ports found.',
                    style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                  ),
                )
              : ListView.separated(
                  key: const ValueKey('network.portScan.list'),
                  // Only the open ones: a list of 24 closed ports buries the answer.
                  itemCount: vm.openPorts.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 4),
                  itemBuilder: (context, index) {
                    final result = vm.openPorts[index];
                    return OmniCard(
                      key: ValueKey('network.portScan.${result.port}'),
                      leftAccent: OmniColors.green,
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              result.label == null
                                  ? '${result.port}'
                                  : '${result.port} · ${result.label}',
                              style: const TextStyle(fontFamily: OmniFonts.mono, fontSize: 13),
                            ),
                          ),
                          const OmniTag(label: 'OPEN', color: OmniColors.green),
                        ],
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

/// Who a domain or address is registered to.
class _WhoisTab extends StatelessWidget {
  const _WhoisTab({required this.vm});

  final NetworkViewModel vm;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _ToolField(
          fieldKey: 'network.whois.target',
          label: 'Domain or IP address',
          hint: 'example.com',
          initial: vm.whoisTarget,
          mono: true,
          onChanged: (v) => vm.whoisTarget = v,
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: Text(
                // Said before the lookup runs, because a WHOIS query sends the typed name to a
                // third party in the clear — a fact worth knowing on a shared or monitored link.
                'Queries port 43 directly, starting at '
                '${initialWhoisServer(vm.whoisTarget.trim().isEmpty ? 'example.com' : vm.whoisTarget)}.',
                style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
              ),
            ),
            const SizedBox(width: 8),
            FilledButton(
              key: const ValueKey('network.whois.run'),
              onPressed: vm.whoisRunning ? null : vm.runWhois,
              child: Text(vm.whoisRunning ? 'Looking up…' : 'Look up'),
            ),
          ],
        ),
        const SizedBox(height: 10),
        if (vm.whoisServers.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Text(
              // Which server said this. A registrar's answer and a registry's answer are different
              // claims about the same domain, and the text alone does not say which you have.
              'Answered by ${vm.whoisServers.join(' → ')}',
              key: const ValueKey('network.whois.servers'),
              style: const TextStyle(
                fontSize: 11,
                fontFamily: OmniFonts.mono,
                color: OmniColors.cyan,
              ),
            ),
          ),
        Expanded(
          child: vm.whoisResult.isEmpty
              ? Center(
                  key: const ValueKey('network.whois.empty'),
                  child: Text(
                    'Registration records for a domain or an IP address.',
                    style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                  ),
                )
              : SingleChildScrollView(
                  key: const ValueKey('network.whois.result'),
                  child: OmniCard(
                    leftAccent: OmniColors.cyan,
                    child: SelectionArea(
                      child: Text(
                        vm.whoisResult,
                        style: TextStyle(
                          fontSize: 11,
                          fontFamily: OmniFonts.mono,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ),
                ),
        ),
      ],
    );
  }
}

class _DnsTab extends StatelessWidget {
  const _DnsTab({required this.vm});

  final NetworkViewModel vm;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _ToolField(
          fieldKey: 'network.dns.target',
          label: 'Name',
          hint: 'example.com',
          initial: vm.dnsTarget,
          mono: true,
          onChanged: (v) => vm.dnsTarget = v,
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: DropdownButtonFormField<String>(
                key: const ValueKey('network.dns.type'),
                initialValue: vm.dnsType,
                decoration: omniInputDecoration(context, labelText: 'Record type'),
                items: [
                  for (final type in dnsRecordTypes)
                    DropdownMenuItem(value: type, child: Text(type)),
                ],
                onChanged: (v) => vm.dnsType = v ?? 'A',
              ),
            ),
            const SizedBox(width: 8),
            FilledButton(
              key: const ValueKey('network.dns.run'),
              onPressed: vm.resolving ? null : vm.runDnsLookup,
              child: Text(vm.resolving ? 'Looking up…' : 'Look up'),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Expanded(
          child: vm.dnsResults.isEmpty
              ? Center(
                  key: const ValueKey('network.dns.empty'),
                  child: Text(
                    'Queries ${fallbackResolvers.join(' then ')} directly.',
                    style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                  ),
                )
              : ListView.separated(
                  key: const ValueKey('network.dns.list'),
                  itemCount: vm.dnsResults.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 6),
                  itemBuilder: (context, index) {
                    final record = vm.dnsResults[index];
                    return OmniCard(
                      key: ValueKey('network.dns.$index'),
                      leftAccent: OmniColors.cyan,
                      child: Row(
                        children: [
                          Expanded(
                            child: SelectionArea(
                              child: Text(
                                record.value,
                                style: const TextStyle(fontFamily: OmniFonts.mono, fontSize: 13),
                              ),
                            ),
                          ),
                          Text(
                            'TTL ${record.ttl}',
                            style: TextStyle(fontSize: 10, color: scheme.onSurfaceVariant),
                          ),
                          const SizedBox(width: 8),
                          OmniTag(label: record.type, color: OmniColors.cyan),
                        ],
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

/// Saved SSH port forwards — the Kotlin's ninth Network tab.
///
/// The transport for this has been ported and tested since session 33 (`ssh_tunnel_manager.dart`);
/// nothing drove it until now, which made it a claim of coverage the app could not honour.
class _TunnelsTab extends StatelessWidget {
  const _TunnelsTab({required this.vm});

  final NetworkViewModel vm;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final servers = context.watch<AppState>().servers;

    if (!vm.canTunnel) {
      return Center(
        child: Text(
          'Port forwarding is unavailable in this build.',
          key: const ValueKey('tunnels.unavailable'),
          style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                // Named in ssh's own flags: anyone who has typed `ssh -L` knows what these rows do.
                'Local (-L), remote (-R) and dynamic (-D) forwards.',
                style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
              ),
            ),
            FilledButton.icon(
              key: const ValueKey('tunnels.add'),
              icon: const Icon(Icons.add, size: 18),
              label: const Text('Add'),
              // A tunnel runs *over* a host, so there is nothing to add before there is one.
              onPressed: servers.isEmpty ? null : () => _openTunnelEditor(context, vm, servers),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Expanded(
          child: servers.isEmpty
              ? Center(
                  child: Text(
                    'Add an SSH host first — a tunnel runs over one.',
                    key: const ValueKey('tunnels.noHosts'),
                    style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                  ),
                )
              : vm.portForwards.isEmpty
              ? Center(
                  child: Text(
                    'No tunnels yet. Add one to forward a port over SSH.',
                    key: const ValueKey('tunnels.empty'),
                    style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                  ),
                )
              : ListView(
                  key: const ValueKey('tunnels.list'),
                  children: [
                    for (final pf in vm.portForwards) _TunnelCard(vm: vm, pf: pf, servers: servers),
                  ],
                ),
        ),
      ],
    );
  }
}

class _TunnelCard extends StatelessWidget {
  const _TunnelCard({required this.vm, required this.pf, required this.servers});

  final NetworkViewModel vm;
  final PortForward pf;
  final List<Server> servers;

  @override
  Widget build(BuildContext context) {
    // Listened to, not merely read: the destination is masked by "Hide addresses", and a widget
    // that reads HostDisplay without subscribing never rebuilds when it changes (convention 2).
    return ListenableBuilder(
      listenable: HostDisplay.instance,
      builder: (context, _) => _buildCard(context),
    );
  }

  Widget _buildCard(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final active = vm.isTunnelActive(pf.id);
    final busy = vm.isTunnelBusy(pf.id);
    final error = vm.tunnelError(pf.id);
    final host = servers.where((s) => s.id == pf.serverId).firstOrNull;

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: OmniCard(
        key: ValueKey('tunnels.card.${pf.id}'),
        leftAccent: active ? OmniColors.green : scheme.onSurfaceVariant,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(pf.name, style: const TextStyle(fontWeight: FontWeight.bold)),
                      Text(
                        tunnelSummary(
                          kind: pf.kind,
                          bindHost: pf.bindHost,
                          bindPort: pf.bindPort,
                          destHost: pf.destHost,
                          destPort: pf.destPort,
                          maskHost: HostDisplay.instance.sensitive,
                        ),
                        key: ValueKey('tunnels.card.${pf.id}.summary'),
                        style: TextStyle(
                          fontSize: 11,
                          fontFamily: OmniFonts.mono,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                      Text(
                        // Naming the missing host rather than letting the row look fine and fail
                        // on toggle.
                        host == null ? 'host no longer exists' : 'via ${host.name}',
                        style: TextStyle(
                          fontSize: 10,
                          color: host == null ? OmniColors.amber : scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                if (busy)
                  const SizedBox(
                    key: ValueKey('tunnels.busy'),
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                else
                  Switch(
                    key: ValueKey('tunnels.card.${pf.id}.toggle'),
                    value: active,
                    onChanged: (_) => vm.toggleTunnel(pf),
                  ),
              ],
            ),
            if (error != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  error,
                  key: ValueKey('tunnels.card.${pf.id}.error'),
                  style: const TextStyle(fontSize: 11, color: OmniColors.red),
                ),
              ),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  key: ValueKey('tunnels.card.${pf.id}.edit'),
                  // Editing a running tunnel would change the row under a live forward, so the
                  // switch has to come down first.
                  onPressed: active ? null : () => _openTunnelEditor(context, vm, servers, pf),
                  child: const Text('Edit', style: TextStyle(fontSize: 12)),
                ),
                TextButton(
                  key: ValueKey('tunnels.card.${pf.id}.delete'),
                  onPressed: () => _confirmDeleteTunnel(context, vm, pf),
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
}

Future<void> _confirmDeleteTunnel(BuildContext context, NetworkViewModel vm, PortForward pf) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      key: const ValueKey('tunnels.delete.dialog'),
      title: Text('Delete "${pf.name}"?'),
      content: const Text('If it is running it will be stopped first.'),
      actions: [
        TextButton(
          key: const ValueKey('tunnels.delete.cancel'),
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: const Text('Cancel'),
        ),
        TextButton(
          key: const ValueKey('tunnels.delete.confirm'),
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: const Text('Delete', style: TextStyle(color: OmniColors.red)),
        ),
      ],
    ),
  );
  if (confirmed ?? false) await vm.deleteTunnel(pf);
}

/// Add or edit a saved tunnel.
Future<void> _openTunnelEditor(
  BuildContext context,
  NetworkViewModel vm,
  List<Server> servers, [
  PortForward? existing,
]) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  builder: (_) => _TunnelEditorSheet(vm: vm, servers: servers, existing: existing),
);

class _TunnelEditorSheet extends StatefulWidget {
  const _TunnelEditorSheet({required this.vm, required this.servers, this.existing});

  final NetworkViewModel vm;
  final List<Server> servers;
  final PortForward? existing;

  @override
  State<_TunnelEditorSheet> createState() => _TunnelEditorSheetState();
}

class _TunnelEditorSheetState extends State<_TunnelEditorSheet> {
  late final _name = TextEditingController(text: widget.existing?.name ?? '');
  late final _bindHost = TextEditingController(text: widget.existing?.bindHost ?? '127.0.0.1');
  late final _bindPort = TextEditingController(text: '${widget.existing?.bindPort ?? ''}');
  late final _destHost = TextEditingController(text: widget.existing?.destHost ?? '');
  late final _destPort = TextEditingController(text: '${widget.existing?.destPort ?? ''}');
  late String _kind = widget.existing?.kind ?? 'local';
  late int? _serverId = widget.existing?.serverId ?? widget.servers.firstOrNull?.id;
  bool _autoStart = false;

  @override
  void initState() {
    super.initState();
    _autoStart = widget.existing?.autoStart ?? false;
  }

  @override
  void dispose() {
    for (final c in [_name, _bindHost, _bindPort, _destHost, _destPort]) {
      c.dispose();
    }
    super.dispose();
  }

  String? get _failure => tunnelFormError(
    name: _name.text,
    kind: _kind,
    serverId: _serverId,
    bindHost: _bindHost.text,
    bindPort: _bindPort.text,
    destHost: _destHost.text,
    destPort: _destPort.text,
  );

  Future<void> _save() async {
    final existing = widget.existing;
    await widget.vm.saveTunnel(
      PortForwardsCompanion.insert(
        id: existing == null ? const Value.absent() : Value(existing.id),
        serverId: _serverId!,
        name: _name.text.trim(),
        kind: Value(_kind),
        bindHost: Value(_bindHost.text.trim()),
        bindPort: int.parse(_bindPort.text.trim()),
        // A dynamic forward has no destination; storing whatever was typed before the mode changed
        // would put a dead address on the card.
        destHost: Value(tunnelHasDestination(_kind) ? _destHost.text.trim() : ''),
        destPort: Value(tunnelHasDestination(_kind) ? int.parse(_destPort.text.trim()) : 0),
        autoStart: Value(_autoStart),
      ),
    );
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final failure = _failure;

    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              widget.existing == null ? 'New tunnel' : 'Edit tunnel',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 12),
            TextField(
              key: const ValueKey('tunnelEditor.name'),
              controller: _name,
              decoration: omniInputDecoration(context, labelText: 'Name'),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 10),
            DropdownButtonFormField<int>(
              key: const ValueKey('tunnelEditor.host'),
              initialValue: _serverId,
              decoration: omniInputDecoration(context, labelText: 'Over host'),
              items: [
                for (final s in widget.servers) DropdownMenuItem(value: s.id, child: Text(s.name)),
              ],
              onChanged: (v) => setState(() => _serverId = v),
            ),
            const SizedBox(height: 10),
            DropdownButtonFormField<String>(
              key: const ValueKey('tunnelEditor.kind'),
              initialValue: _kind,
              decoration: omniInputDecoration(context, labelText: 'Mode'),
              items: [
                for (final entry in tunnelKinds.entries)
                  DropdownMenuItem(value: entry.key, child: Text(entry.value)),
              ],
              onChanged: (v) => setState(() => _kind = v ?? _kind),
            ),
            const SizedBox(height: 10),
            TextField(
              key: const ValueKey('tunnelEditor.bindHost'),
              controller: _bindHost,
              decoration: omniInputDecoration(
                context,
                labelText: 'Bind address',
                helperText: '127.0.0.1 keeps it on this device; 0.0.0.0 exposes it to the network',
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 10),
            TextField(
              key: const ValueKey('tunnelEditor.bindPort'),
              controller: _bindPort,
              keyboardType: TextInputType.number,
              decoration: omniInputDecoration(context, labelText: 'Bind port'),
              onChanged: (_) => setState(() {}),
            ),
            if (tunnelHasDestination(_kind)) ...[
              const SizedBox(height: 10),
              TextField(
                key: const ValueKey('tunnelEditor.destHost'),
                controller: _destHost,
                decoration: omniInputDecoration(context, labelText: 'Destination host'),
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: 10),
              TextField(
                key: const ValueKey('tunnelEditor.destPort'),
                controller: _destPort,
                keyboardType: TextInputType.number,
                decoration: omniInputDecoration(context, labelText: 'Destination port'),
                onChanged: (_) => setState(() {}),
              ),
            ],
            const SizedBox(height: 10),
            // What this mode actually does, in a sentence. The flags are the precise name and the
            // sentence is the explanation; showing only one of the two leaves somebody guessing.
            Text(
              switch (_kind) {
                'remote' =>
                  'The SSH host listens on the bind port and forwards back to a '
                      'destination reachable from this device.',
                'dynamic' =>
                  'Opens a SOCKS4/4a/5 proxy on the bind address; point apps at it to route '
                      'through the SSH host.',
                _ =>
                  'This device listens on the bind address and forwards to a destination '
                      'reachable from the SSH host.',
              },
              key: const ValueKey('tunnelEditor.explain'),
              style: TextStyle(fontSize: 11, color: Theme.of(context).colorScheme.onSurfaceVariant),
            ),
            SwitchListTile(
              key: const ValueKey('tunnelEditor.autoStart'),
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: const Text('Start when OmniTerm opens', style: TextStyle(fontSize: 13)),
              subtitle: Text(
                // Saying the lifetime plainly: a tunnel is not a system service, and a user who
                // expects it to survive the app being closed would be wrong in a way that matters.
                'Only while the app is running — closing OmniTerm takes the tunnel down.',
                style: TextStyle(
                  fontSize: 11,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
              value: _autoStart,
              onChanged: (v) => setState(() => _autoStart = v),
            ),
            if (failure != null)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Text(
                  failure,
                  key: const ValueKey('tunnelEditor.error'),
                  style: const TextStyle(fontSize: 12, color: OmniColors.red),
                ),
              ),
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    key: const ValueKey('tunnelEditor.cancel'),
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Cancel'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: FilledButton(
                    key: const ValueKey('tunnelEditor.save'),
                    // Disabled while invalid, with the reason on screen — a port nobody chose is
                    // exactly what the Kotlin's PR #67 was about.
                    onPressed: failure == null ? _save : null,
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
