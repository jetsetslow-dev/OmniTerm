import 'dart:async';

import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../../data/app_database.dart';
import '../../../data/network/network_probe.dart';
import '../../../domain/external_ui_requests.dart';
import '../../../domain/host_display.dart';
import '../../../domain/input_validation.dart';
import '../../navigation.dart';
import '../../theme/colors.dart';
import '../../theme/typography.dart';
import '../../view_model/app_state.dart';
import '../../view_model/network_view_model.dart';
import '../../widgets/omni_components.dart';
import '../../widgets/omni_confirm.dart';
import '../../widgets/popup_scroll_behavior.dart';
import '../../widgets/text_controllers_state.dart';

/// The Network tools, ported from `NetworkToolView` in `ui/ToolsScreen.kt`: nine device-side tools
/// under one scrollable tab row. Ping, Traceroute and Port Scan share one target.
class NetworkScreen extends StatefulWidget {
  const NetworkScreen({super.key});

  static const tabLabels = {
    NetworkTab.hostScan: 'Host Scan',
    NetworkTab.wakeOnLan: 'Wake-on-LAN',
    NetworkTab.ping: 'Ping',
    NetworkTab.traceroute: 'Traceroute',
    NetworkTab.portScan: 'Port Scan',
    NetworkTab.dnsLookup: 'DNS Lookup',
    NetworkTab.whois: 'WHOIS',
    NetworkTab.speedTest: 'Speed Test',
    NetworkTab.tunnels: 'Tunnels',
  };

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

  @override
  Widget build(BuildContext context) {
    final vm = context.watch<NetworkViewModel>();
    return ToolScaffold(
      title: 'Network tools',
      keyPrefix: 'network',
      onBack: () => context.read<NavigationController>().navigateTo(Screen.tools),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Kotlin's PrimaryScrollableTabRow: edge padding 0, 12sp labels.
          OmniScrollableTabRow(
            key: const ValueKey('network.tabs'),
            labels: [for (final tab in NetworkTab.values) NetworkScreen.tabLabels[tab]!],
            selectedIndex: vm.activeTab.index,
            onSelected: (i) => vm.activeTab = NetworkTab.values[i],
            tabKeys: [for (final tab in NetworkTab.values) ValueKey('network.tab.${tab.name}')],
          ),
          Expanded(
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
        ],
      ),
    );
  }
}

// ── shared pieces ────────────────────────────────────────────────────────────────

Color _muted(BuildContext context) => Theme.of(context).colorScheme.onSurfaceVariant;

/// A scrolling column of a tab's controls with Kotlin's 12dp padding and spacing.
Widget _tabColumn(List<Widget> children, {Key? key}) => ScrollConfiguration(
  behavior: const PopupScrollBehavior(popupsOnly: false),
  child: ListView(
    key: key,
    padding: const EdgeInsets.all(12),
    children: [
      for (var i = 0; i < children.length; i++) ...[
        if (i > 0) const SizedBox(height: 12),
        children[i],
      ],
    ],
  ),
);

/// A text field bound to a view-model string. Owns its controller, and follows the value when
/// another tab fills it (a scanned host sent to Ping).
class _BoundField extends StatefulWidget {
  const _BoundField({
    required this.fieldKey,
    required this.label,
    required this.value,
    required this.onChanged,
    this.keyboardType,
    this.inputFormatters,
    this.errorText,
  });

  final String fieldKey;
  final String label;
  final String value;
  final ValueChanged<String> onChanged;
  final TextInputType? keyboardType;
  final List<TextInputFormatter>? inputFormatters;
  final String? errorText;

  @override
  State<_BoundField> createState() => _BoundFieldState();
}

class _BoundFieldState extends State<_BoundField> {
  late final _controller = TextEditingController(text: widget.value);

  @override
  void didUpdateWidget(_BoundField old) {
    super.didUpdateWidget(old);
    if (widget.value != _controller.text) _controller.text = widget.value;
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => TextField(
    key: ValueKey(widget.fieldKey),
    controller: _controller,
    keyboardType: widget.keyboardType,
    inputFormatters: widget.inputFormatters,
    onChanged: widget.onChanged,
    decoration: omniInputDecoration(context, labelText: widget.label, errorText: widget.errorText),
  );
}

/// Kotlin's full-width action Button with an in-button spinner while [busy].
Widget _actionButton({
  required Key key,
  required String label,
  required VoidCallback? onPressed,
  bool busy = false,
  String? busyLabel,
  Color? color,
  Widget? icon,
}) => SizedBox(
  width: double.infinity,
  child: FilledButton(
    key: key,
    style: color == null ? null : FilledButton.styleFrom(backgroundColor: color),
    onPressed: onPressed,
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (busy) ...[
          const SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
          ),
          if (busyLabel != null) const SizedBox(width: 8),
        ] else if (icon != null) ...[
          icon,
          const SizedBox(width: 8),
        ],
        if (!busy || busyLabel != null) Text(busy ? busyLabel! : label),
      ],
    ),
  ),
);

/// Monospace output lines in a card, following the newest line as Kotlin's list does.
class _OutputCard extends StatefulWidget {
  const _OutputCard({required this.cardKey, required this.lines, required this.isFailure});

  final String cardKey;
  final List<String> lines;
  final bool Function(String line) isFailure;

  @override
  State<_OutputCard> createState() => _OutputCardState();
}

class _OutputCardState extends State<_OutputCard> {
  final _scroll = ScrollController();

  @override
  void didUpdateWidget(_OutputCard old) {
    super.didUpdateWidget(old);
    if (widget.lines.length != old.lines.length) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scroll.hasClients) {
          _scroll.animateTo(
            _scroll.position.maxScrollExtent,
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOut,
          );
        }
      });
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final onSurface = Theme.of(context).colorScheme.onSurface;
    return OmniCard(
      key: ValueKey(widget.cardKey),
      child: SizedBox(
        height: 320,
        child: SelectionArea(
          child: ListView.separated(
            controller: _scroll,
            padding: const EdgeInsets.all(10),
            itemCount: widget.lines.length,
            separatorBuilder: (_, _) => const SizedBox(height: 2),
            itemBuilder: (_, i) {
              final line = widget.lines[i];
              return Text(
                line,
                style: composeBody(
                  fontSize: 11,
                  fontFamily: OmniFonts.mono,
                  color: widget.isFailure(line) ? OmniColors.red : onSurface,
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

extension on ScannedHost {
  /// Kotlin's `isOnline`: answered the sweep, as opposed to being known only from the ARP cache.
  bool get isOnline => latency != null || openPorts.isNotEmpty;

  String get displayName => (hostname ?? '').isEmpty ? address : hostname!;
}

/// Kotlin's `ScannedHostCard`: status dot, IP, hostname, MAC + vendor and open ports.
class _ScannedHostCard extends StatelessWidget {
  const _ScannedHostCard({
    required this.host,
    required this.accent,
    required this.onTap,
    this.trailing,
  });

  final ScannedHost host;
  final Color accent;
  final VoidCallback onTap;
  final IconData? trailing;

  @override
  Widget build(BuildContext context) {
    final muted = _muted(context);
    final mac = host.macAddress.isEmpty ? 'MAC unavailable' : host.macAddress;
    return OmniCard(
      key: ValueKey('network.scan.host.${host.address}'),
      leftAccent: accent,
      inset: const EdgeInsets.all(12),
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 4,
        children: [
          Row(
            children: [
              Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: host.isOnline ? const Color(0xFF10B981) : const Color(0xFFFF0000),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  host.address,
                  style: composeBody(
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                    fontFamily: OmniFonts.mono,
                  ),
                ),
              ),
              if (trailing != null)
                Icon(trailing, size: 18, color: OmniColors.cyan, semanticLabel: 'Actions'),
            ],
          ),
          if ((host.hostname ?? '').isNotEmpty)
            Text(
              host.hostname!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: composeBody(fontSize: 12, color: Theme.of(context).colorScheme.onSurface),
            ),
          Text(
            host.vendor.isEmpty ? mac : '$mac · ${host.vendor}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: composeBody(fontSize: 11, color: muted),
          ),
          if (host.openPorts.isNotEmpty)
            Text(
              'Open ports: ${host.openPorts.join(', ')}',
              style: composeBody(fontSize: 11, fontFamily: OmniFonts.mono, color: OmniColors.green),
            ),
        ],
      ),
    );
  }
}

/// Kotlin's `LanHostPickerDialog`: the shared sweep, with a Scan/Rescan button, picking an address.
Future<String?> _pickLanHost(BuildContext context, NetworkViewModel vm) {
  // Reuse a fresh sweep; otherwise start one the dialog shows progress for.
  unawaited(vm.refreshLanScan());
  return showDialog<String>(
    context: context,
    builder: (dialogContext) => ListenableBuilder(
      listenable: vm,
      builder: (dialogContext, _) {
        final hosts = vm.scanResults;
        return AlertDialog(
          key: const ValueKey('network.picker.dialog'),
          title: const Text('Pick a LAN host'),
          content: SizedBox(
            width: double.maxFinite,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              spacing: 8,
              children: [
                _actionButton(
                  key: const ValueKey('network.picker.scan'),
                  label: hosts.isEmpty ? 'Scan LAN' : 'Rescan LAN',
                  busy: vm.scanning,
                  busyLabel: 'Scanning network…',
                  onPressed: vm.scanning ? null : () => vm.refreshLanScan(force: true),
                ),
                if (!vm.scanning && hosts.isEmpty)
                  Text(
                    'No hosts yet — run a scan.',
                    style: composeDialogBody(fontSize: 12, color: _muted(dialogContext)),
                  ),
                Flexible(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 360),
                    child: ListView.separated(
                      shrinkWrap: true,
                      itemCount: hosts.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 8),
                      itemBuilder: (_, i) {
                        final host = hosts[i];
                        return _ScannedHostCard(
                          host: host,
                          accent: vm.sharedTarget == host.address
                              ? OmniColors.cyan
                              : host.isOnline
                              ? OmniColors.green
                              : _muted(dialogContext),
                          onTap: () => Navigator.of(dialogContext).pop(host.address),
                        );
                      },
                    ),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              key: const ValueKey('network.picker.close'),
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Close'),
            ),
          ],
        );
      },
    ),
  );
}

/// Kotlin's `LanHostPicker`: one outlined button that opens the picker and fills the shared target.
Widget _lanHostPicker(BuildContext context, NetworkViewModel vm) => SizedBox(
  width: double.infinity,
  child: OutlinedButton.icon(
    key: const ValueKey('network.picker'),
    icon: const Icon(Icons.lan, size: 18),
    label: const Text('Pick LAN host', style: TextStyle(fontSize: 12)),
    onPressed: () async {
      final address = await _pickLanHost(context, vm);
      if (address == null) return;
      vm.sharedTarget = address;
      vm.fieldEdited();
    },
  ),
);

// ── Host Scan ────────────────────────────────────────────────────────────────────

class _HostScanTab extends StatelessWidget {
  const _HostScanTab({required this.vm});

  final NetworkViewModel vm;

  @override
  Widget build(BuildContext context) {
    final hosts = vm.scanResults;
    final muted = _muted(context);
    return _tabColumn(key: const ValueKey('network.scan.list'), [
      Text(
        'Sweep your local network and gather as much detail as possible per host: hostname, '
        'MAC + vendor, and which common ports answer. Tap a host for actions — save it, ping, '
        'port scan, and more.',
        style: composeBody(fontSize: 11, color: muted),
      ),
      _actionButton(
        key: const ValueKey('network.scan.button'),
        label: hosts.isEmpty ? 'Scan network' : 'Rescan network',
        icon: const Icon(Icons.lan, size: 18),
        busy: vm.scanning,
        busyLabel: 'Scanning network…',
        onPressed: vm.scanning ? null : () => vm.refreshLanScan(force: true),
      ),
      if (vm.error != null && !vm.scanning)
        Text(
          vm.error!,
          key: const ValueKey('network.error'),
          style: composeBody(fontSize: 12, color: OmniColors.red),
        ),
      if (!vm.scanning && hosts.isEmpty)
        Text('No hosts yet — run a scan.', style: composeBody(fontSize: 12, color: muted)),
      for (final host in hosts)
        _ScannedHostCard(
          host: host,
          accent: host.isOnline ? OmniColors.green : muted,
          trailing: Icons.more_vert,
          onTap: () => _openHostActions(context, vm, host),
        ),
    ]);
  }
}

/// Kotlin's `ScannedHostActionsSheet`: every tool that takes an address, plus saving the host.
Future<void> _openHostActions(BuildContext context, NetworkViewModel vm, ScannedHost host) async {
  final saved = context
      .read<AppState>()
      .servers
      .where((server) => server.host == host.address)
      .firstOrNull;
  final action = await showDialog<String>(
    context: context,
    builder: (dialogContext) {
      final muted = _muted(dialogContext);
      Widget row(String value, IconData icon, String label, String detail, {Color? tint}) =>
          InkWell(
            key: ValueKey('network.scan.action.$value'),
            onTap: () => Navigator.of(dialogContext).pop(value),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: Row(
                children: [
                  Icon(icon, size: 20, color: tint ?? muted),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(label, style: composeDialogBody(fontSize: 14)),
                        Text(
                          detail,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: composeDialogBody(fontSize: 11, color: muted),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          );
      return AlertDialog(
        key: const ValueKey('network.scan.actions'),
        scrollable: true,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              host.displayName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            if ((host.hostname ?? '').isNotEmpty)
              Text(
                host.address,
                style: composeDialogBody(fontSize: 12, fontFamily: OmniFonts.mono, color: muted),
              ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (saved != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  'Already saved as "${saved.name}".',
                  style: composeDialogBody(fontSize: 12, color: OmniColors.cyan),
                ),
              )
            else
              row(
                'addServer',
                Icons.add_circle,
                'Add as OmniTerm host',
                host.openPorts.contains(22)
                    ? 'SSH is open on port 22'
                    : 'Opens the add-host form for ${host.address}',
                tint: OmniColors.cyan,
              ),
            row('ping', Icons.network_ping, 'Ping', '4 echo requests from this device'),
            row('traceroute', Icons.route, 'Traceroute', 'Trace the path to this host'),
            row(
              'portScan',
              Icons.network_check,
              'Port scan',
              host.openPorts.isEmpty
                  ? 'Scan the common port list'
                  : 'Includes the ${host.openPorts.length} port(s) the sweep found open',
            ),
            row('dnsLookup', Icons.dns, 'DNS lookup', 'Resolve ${host.displayName}'),
            if (host.macAddress.isNotEmpty)
              row(
                'wol',
                Icons.power_settings_new,
                'Add as Wake-on-LAN target',
                'MAC ${host.macAddress} is known, so this host can be woken',
              ),
            row('copy', Icons.content_copy, 'Copy IP address', host.address),
          ],
        ),
        actions: [
          TextButton(
            key: const ValueKey('network.scan.actions.close'),
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Close'),
          ),
        ],
      );
    },
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
      vm.pingCount = 4;
      unawaited(vm.runForHost(host.address, NetworkTab.ping));
    case 'traceroute':
      unawaited(vm.runForHost(host.address, NetworkTab.traceroute));
    case 'portScan':
      unawaited(vm.runForHost(host.address, NetworkTab.portScan, knownOpenPorts: host.openPorts));
    case 'dnsLookup':
      unawaited(vm.runForHost(host.displayName, NetworkTab.dnsLookup));
    case 'wol':
      vm.activeTab = NetworkTab.wakeOnLan;
      await _openWolEditor(context, vm, scanned: host);
    case 'copy':
      await Clipboard.setData(ClipboardData(text: host.address));
  }
}

// ── Ping / Traceroute / Port Scan ────────────────────────────────────────────────

class _PingTab extends StatefulWidget {
  const _PingTab({required this.vm});

  final NetworkViewModel vm;

  @override
  State<_PingTab> createState() => _PingTabState();
}

class _PingTabState extends State<_PingTab> {
  late String _tries = '${widget.vm.pingCount}';

  @override
  Widget build(BuildContext context) {
    final vm = widget.vm;
    // 0 is meaningful (ping until stopped), so the floor is 0.
    final triesError = countError(_tries, min: 0, max: 9999);
    return _tabColumn([
      _lanHostPicker(context, vm),
      _BoundField(
        fieldKey: 'network.target',
        label: 'Hostname or IP address',
        value: vm.pingTarget,
        keyboardType: TextInputType.url,
        onChanged: (v) {
          vm.pingTarget = v;
          vm.fieldEdited();
        },
      ),
      _BoundField(
        fieldKey: 'network.ping.tries',
        label: 'Tries (0 = keep pinging until stopped)',
        value: _tries,
        keyboardType: TextInputType.number,
        inputFormatters: [
          FilteringTextInputFormatter.digitsOnly,
          LengthLimitingTextInputFormatter(4),
        ],
        errorText: triesError,
        onChanged: (v) => setState(() => _tries = v),
      ),
      _actionButton(
        key: const ValueKey('network.ping.start'),
        label: 'Start Ping',
        busy: vm.pinging,
        busyLabel: 'Stop',
        onPressed: vm.pinging
            ? vm.stopPing
            : vm.pingTarget.trim().isNotEmpty && triesError == null
            ? () {
                vm.pingCount = int.parse(_tries.trim());
                vm.runPing();
              }
            : null,
      ),
      Text(
        'Pings are sent from this device, so they tell you whether the HOST is reachable on your '
        'current network — independent of SSH.',
        style: composeBody(fontSize: 11, color: _muted(context)),
      ),
      if (vm.error != null) _errorText(vm.error!),
      if (vm.pingLines.isNotEmpty)
        _OutputCard(
          cardKey: 'network.ping.output',
          lines: vm.pingLines,
          isFailure: (line) =>
              line.toLowerCase().contains('failed') ||
              line.toLowerCase().contains('unreachable') ||
              line.contains('100% packet loss'),
        ),
    ]);
  }
}

Widget _errorText(String message) => Text(
  message,
  key: const ValueKey('network.error'),
  style: composeBody(fontSize: 13, fontFamily: OmniFonts.mono, color: OmniColors.red),
);

class _TracerouteTab extends StatelessWidget {
  const _TracerouteTab({required this.vm});

  final NetworkViewModel vm;

  @override
  Widget build(BuildContext context) => _tabColumn([
    _lanHostPicker(context, vm),
    _BoundField(
      fieldKey: 'network.target',
      label: 'Hostname or IP address',
      value: vm.tracerouteTarget,
      keyboardType: TextInputType.url,
      onChanged: (v) {
        vm.tracerouteTarget = v;
        vm.fieldEdited();
      },
    ),
    _actionButton(
      key: const ValueKey('network.traceroute.start'),
      label: 'Start Traceroute',
      busy: vm.tracerouteRunning,
      busyLabel: 'Stop',
      onPressed: vm.tracerouteRunning
          ? vm.stopTraceroute
          : vm.tracerouteTarget.trim().isNotEmpty
          ? vm.runTraceroute
          : null,
    ),
    Text(
      "Traces each network hop from this device to the host. Uses the platform traceroute; if it "
      "isn't available, a clear message is shown.",
      style: composeBody(fontSize: 11, color: _muted(context)),
    ),
    if (vm.error != null) _errorText(vm.error!),
    if (vm.tracerouteLines.isNotEmpty)
      _OutputCard(
        cardKey: 'network.traceroute.output',
        lines: vm.tracerouteLines,
        isFailure: (line) =>
            line.toLowerCase().contains('not available') || line.toLowerCase().contains('failed'),
      ),
  ]);
}

class _PortScanTab extends StatelessWidget {
  const _PortScanTab({required this.vm});

  final NetworkViewModel vm;

  @override
  Widget build(BuildContext context) {
    final muted = _muted(context);
    return _tabColumn([
      _lanHostPicker(context, vm),
      _BoundField(
        fieldKey: 'network.target',
        label: 'Target Host IP (Scan pointer)',
        value: vm.portScanTarget,
        keyboardType: TextInputType.phone,
        onChanged: (v) {
          vm.portScanTarget = v;
          vm.fieldEdited();
        },
      ),
      _BoundField(
        fieldKey: 'network.portScan.ports',
        label: 'Ports list range (comma-split)',
        value: vm.portSpec,
        keyboardType: TextInputType.phone,
        onChanged: (v) => vm.portSpec = v,
      ),
      _actionButton(
        key: const ValueKey('network.portScan.start'),
        label: 'Initiate Range Scan',
        busy: vm.portScanning,
        onPressed: vm.portScanTarget.trim().isNotEmpty && !vm.portScanning ? vm.runPortScan : null,
      ),
      if (vm.error != null) _errorText(vm.error!),
      for (final result in vm.portResults)
        OmniCard(
          key: ValueKey('network.portScan.result.${result.port}'),
          leftAccent: result.open ? OmniColors.green : muted,
          inset: const EdgeInsets.all(12),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  'Port ${result.port}',
                  style: composeBody(fontWeight: FontWeight.bold, fontFamily: OmniFonts.mono),
                ),
              ),
              Text(
                result.open ? 'Open' : 'Closed',
                style: composeBody(
                  fontWeight: FontWeight.bold,
                  color: result.open ? const Color(0xFF10B981) : Colors.grey,
                ),
              ),
            ],
          ),
        ),
    ]);
  }
}

// ── Wake-on-LAN ──────────────────────────────────────────────────────────────────

class _WolTab extends StatelessWidget {
  const _WolTab({required this.vm});

  final NetworkViewModel vm;

  @override
  Widget build(BuildContext context) {
    final muted = _muted(context);
    return ScrollConfiguration(
      behavior: const PopupScrollBehavior(popupsOnly: false),
      child: ListView(
        key: const ValueKey('network.wol.list'),
        padding: const EdgeInsets.only(bottom: 12),
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                key: const ValueKey('network.wol.scan'),
                icon: const Icon(Icons.lan, size: 18),
                label: const Text('Scan LAN to add a target', style: TextStyle(fontSize: 12)),
                onPressed: () async {
                  final address = await _pickLanHost(context, vm);
                  if (address == null || !context.mounted) return;
                  final host = vm.scanResults.where((h) => h.address == address).firstOrNull;
                  await _openWolEditor(context, vm, scanned: host ?? ScannedHost(address: address));
                },
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'Saved targets',
                    style: composeBody(fontSize: 13, fontWeight: FontWeight.bold, color: muted),
                  ),
                ),
                SizedBox(
                  height: 36,
                  child: FilledButton.icon(
                    key: const ValueKey('network.wol.add'),
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                    ),
                    icon: const Icon(Icons.add, size: 16),
                    label: const Text('Add target', style: TextStyle(fontSize: 12)),
                    onPressed: () => _openWolEditor(context, vm),
                  ),
                ),
              ],
            ),
          ),
          for (final target in vm.wolTargets)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
              child: _WolCard(vm: vm, target: target),
            ),
        ],
      ),
    );
  }
}

class _WolCard extends StatelessWidget {
  const _WolCard({required this.vm, required this.target});

  final NetworkViewModel vm;
  final WolTarget target;

  @override
  Widget build(BuildContext context) {
    final muted = _muted(context);
    final display = HostDisplay.instance;
    final detail = StringBuffer(
      'MAC: ${display.sensitive(target.macAddress)} · Port ${target.port}',
    );
    if (target.ipAddress.isNotEmpty && !display.hideSensitiveInfo) {
      detail.write(' · ${target.ipAddress}');
    }
    return OmniCard(
      key: ValueKey('network.wol.${target.id}'),
      leftAccent: OmniColors.green,
      inset: const EdgeInsets.all(16),
      child: Row(
        children: [
          _WolStatusDot(vm: vm, target: target),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(target.name, style: composeBody(fontWeight: FontWeight.bold)),
                Text(detail.toString(), style: composeBody(fontSize: 12, color: muted)),
                if (target.notes.trim().isNotEmpty)
                  Text(
                    target.notes,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: composeBody(fontSize: 11, color: muted, fontStyle: FontStyle.italic),
                  ),
              ],
            ),
          ),
          SizedBox(
            height: 36,
            child: FilledButton.icon(
              key: ValueKey('network.wol.${target.id}.wake'),
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFF10B981),
                padding: const EdgeInsets.symmetric(horizontal: 10),
              ),
              icon: const Icon(Icons.power, size: 15),
              label: const Text(
                'Wake',
                maxLines: 1,
                style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold),
              ),
              onPressed: () => _confirmWake(context),
            ),
          ),
          IconButton(
            key: ValueKey('network.wol.${target.id}.edit'),
            tooltip: 'Edit WOL target',
            icon: const Icon(Icons.edit, color: OmniColors.cyan),
            onPressed: () => _openWolEditor(context, vm, existing: target),
          ),
          IconButton(
            key: ValueKey('network.wol.${target.id}.delete'),
            tooltip: 'Delete WOL target',
            icon: const Icon(Icons.delete, color: Color(0xFFFF0000)),
            onPressed: () async {
              final confirmed = await showOmniConfirm(
                context,
                title: 'Delete WOL target?',
                message: 'Delete "${target.name}" from Wake-on-LAN targets?',
                confirmLabel: 'Delete',
                destructive: true,
                keyPrefix: 'network.wol.deleteDialog',
              );
              if (confirmed) await vm.deleteWolTarget(target);
            },
          ),
        ],
      ),
    );
  }

  Future<void> _confirmWake(BuildContext context) async {
    final confirmed = await showOmniConfirm(
      context,
      title: 'Send wake packet?',
      message: 'Send a Wake-on-LAN magic packet to "${target.name}" (${target.macAddress})?',
      confirmLabel: 'Wake',
      destructive: true,
      keyPrefix: 'network.wol.wakeDialog',
    );
    if (!confirmed || !context.mounted) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    final message = await vm.wake(target);
    messenger?.showSnackBar(SnackBar(content: Text(message)));
  }
}

/// Kotlin's `WolStatusDot`: polls every 10s while visible. Grey = no IP / checking, green = up,
/// red = no response.
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
    _poll();
    _timer = Timer.periodic(const Duration(seconds: 10), (_) => _poll());
  }

  Future<void> _poll() async {
    final online = await widget.vm.wolOnlineStatus(widget.target);
    if (mounted) setState(() => _online = online);
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(right: 10),
    child: Container(
      width: 10,
      height: 10,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: switch (_online) {
          true => const Color(0xFF10B981),
          false => const Color(0xFFFF0000),
          null => Colors.grey,
        },
      ),
    ),
  );
}

Future<void> _openWolEditor(
  BuildContext context,
  NetworkViewModel vm, {
  WolTarget? existing,
  ScannedHost? scanned,
}) => showDialog<void>(
  context: context,
  builder: (_) => _WolDialog(vm: vm, existing: existing, scanned: scanned),
);

/// Kotlin's "Configure WOL Pointer" / "Edit WOL Pointer" dialog.
class _WolDialog extends StatefulWidget {
  const _WolDialog({required this.vm, this.existing, this.scanned});

  final NetworkViewModel vm;
  final WolTarget? existing;
  final ScannedHost? scanned;

  @override
  State<_WolDialog> createState() => _WolDialogState();
}

class _WolDialogState extends State<_WolDialog> with TextControllersState {
  late final WolTarget? _t = widget.existing;
  late final ScannedHost? _s = widget.scanned;
  late final _name = TextEditingController(
    text:
        _t?.name ?? (_s == null ? '' : ((_s.hostname ?? '').isEmpty ? 'LAN Device' : _s.hostname!)),
  );
  late final _mac = TextEditingController(text: _t?.macAddress ?? _s?.macAddress ?? '');
  late final _broadcast = TextEditingController(
    text:
        _t?.broadcastIp ??
        (_s == null
            ? '192.168.1.255'
            : '${_s.address.substring(0, _s.address.lastIndexOf('.'))}.255'),
  );
  late final _ip = TextEditingController(text: _t?.ipAddress ?? _s?.address ?? '');
  late final _port = TextEditingController(text: '${_t?.port ?? 9}');
  late final _notes = TextEditingController(text: _t?.notes ?? '');
  String? _failure;

  @override
  List<TextEditingController> get textControllers => [_name, _mac, _broadcast, _ip, _port, _notes];

  Future<void> _save() async {
    final failure = await widget.vm.saveWolTarget(
      existing: _t,
      name: _name.text,
      macAddress: _mac.text,
      broadcastIp: _broadcast.text,
      ipAddress: _ip.text,
      port: int.parse(_port.text.trim()),
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
    final macError = macAddressError(_mac.text);
    final portErr = portError(_port.text);
    final canSave =
        _name.text.trim().isNotEmpty &&
        _broadcast.text.trim().isNotEmpty &&
        macError == null &&
        portErr == null;
    Widget field(
      String key,
      TextEditingController c,
      String label, {
      String? error,
      TextInputType? keyboard,
      List<TextInputFormatter>? formatters,
      int? minLines,
    }) => TextField(
      key: ValueKey('network.wol.editor.$key'),
      controller: c,
      keyboardType: keyboard,
      inputFormatters: formatters,
      minLines: minLines,
      maxLines: minLines == null ? 1 : null,
      decoration: omniInputDecoration(context, labelText: label, errorText: error),
    );
    return AlertDialog(
      key: const ValueKey('network.wol.editor'),
      scrollable: true,
      title: Text(_t == null ? 'Configure WOL Pointer' : 'Edit WOL Pointer'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: 10,
        children: [
          field('name', _name, 'Machine Name'),
          field('mac', _mac, 'MAC Address target', error: _mac.text.isNotEmpty ? macError : null),
          field(
            'broadcast',
            _broadcast,
            'Broadcast IP network segment',
            keyboard: TextInputType.phone,
          ),
          field('ip', _ip, 'Host IP address (for online status)', keyboard: TextInputType.phone),
          field(
            'port',
            _port,
            'UDP port',
            error: portErr,
            keyboard: TextInputType.number,
            formatters: [FilteringTextInputFormatter.digitsOnly],
          ),
          field('notes', _notes, 'Notes', minLines: 2),
          if (_failure != null)
            Text(_failure!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
        ],
      ),
      actions: [
        TextButton(
          key: const ValueKey('network.wol.editor.cancel'),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const ValueKey('network.wol.editor.save'),
          onPressed: canSave ? _save : null,
          child: Text(_t == null ? 'Add configuration' : 'Save changes'),
        ),
      ],
    );
  }
}

// ── DNS / WHOIS / Speed Test ─────────────────────────────────────────────────────

/// A read-only field with a dropdown arrow, as Kotlin's type and server pickers are.
Widget _menuField<T>(
  BuildContext context, {
  required String fieldKey,
  required String label,
  required String shown,
  required List<(T, String)> options,
  required ValueChanged<T> onSelected,
}) => TextField(
  key: ValueKey(fieldKey),
  readOnly: true,
  controller: TextEditingController(text: shown),
  decoration: omniInputDecoration(
    context,
    labelText: label,
    suffixIcon: PopupMenuButton<T>(
      key: ValueKey('$fieldKey.menu'),
      tooltip: 'Pick $label',
      icon: const Icon(Icons.arrow_drop_down),
      onSelected: onSelected,
      itemBuilder: (_) => [for (final (v, l) in options) PopupMenuItem(value: v, child: Text(l))],
    ),
  ),
);

class _DnsTab extends StatelessWidget {
  const _DnsTab({required this.vm});

  final NetworkViewModel vm;

  static const _types = ['A', 'AAAA', 'MX', 'CNAME', 'TXT', 'NS'];

  @override
  Widget build(BuildContext context) {
    final muted = _muted(context);
    return _tabColumn([
      _BoundField(
        fieldKey: 'network.dns.target',
        label: 'Domain Name / Hostname',
        value: vm.dnsTarget,
        keyboardType: TextInputType.url,
        onChanged: (v) {
          vm.dnsTarget = v;
          vm.fieldEdited();
        },
      ),
      _menuField<String>(
        context,
        fieldKey: 'network.dns.type',
        label: 'Query Type',
        shown: vm.dnsType,
        options: [for (final t in _types) (t, t)],
        onSelected: (t) {
          vm.dnsType = t;
          vm.fieldEdited();
        },
      ),
      _actionButton(
        key: const ValueKey('network.dns.run'),
        label: 'Run DNS Query',
        busy: vm.resolving,
        busyLabel: 'Querying...',
        onPressed: vm.dnsTarget.trim().isNotEmpty && !vm.resolving ? vm.runDnsLookup : null,
      ),
      if (vm.error != null) _errorText(vm.error!),
      for (final record in vm.dnsResults)
        OmniCard(
          leftAccent: OmniColors.cyan,
          inset: const EdgeInsets.all(12),
          child: SelectionArea(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        record.name,
                        style: composeBody(fontSize: 14, fontWeight: FontWeight.bold),
                      ),
                    ),
                    Text(
                      record.type,
                      style: composeBody(
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                        color: OmniColors.cyan,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  'Value: ${record.value}',
                  style: composeBody(fontSize: 13, fontFamily: OmniFonts.mono),
                ),
                Text('TTL: ${record.ttl}', style: composeBody(fontSize: 11, color: muted)),
              ],
            ),
          ),
        ),
    ]);
  }
}

class _WhoisTab extends StatelessWidget {
  const _WhoisTab({required this.vm});

  final NetworkViewModel vm;

  @override
  Widget build(BuildContext context) => _tabColumn([
    _BoundField(
      fieldKey: 'network.whois.target',
      label: 'Domain Name or IP Address',
      value: vm.whoisTarget,
      keyboardType: TextInputType.url,
      onChanged: (v) {
        vm.whoisTarget = v;
        vm.fieldEdited();
      },
    ),
    _actionButton(
      key: const ValueKey('network.whois.run'),
      label: 'Run WHOIS Query',
      busy: vm.whoisRunning,
      busyLabel: 'Querying...',
      onPressed: vm.whoisTarget.trim().isNotEmpty && !vm.whoisRunning ? vm.runWhois : null,
    ),
    if (vm.error != null) _errorText(vm.error!),
    if (vm.whoisResult.trim().isNotEmpty)
      OmniCard(
        key: const ValueKey('network.whois.result'),
        child: SizedBox(
          height: 360,
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(10),
            child: SelectableText(
              vm.whoisResult,
              style: composeBody(
                fontSize: 11,
                fontFamily: OmniFonts.mono,
                color: Theme.of(context).colorScheme.onSurface,
              ),
            ),
          ),
        ),
      ),
  ]);
}

class _SpeedTestTab extends StatelessWidget {
  const _SpeedTestTab({required this.vm});

  final NetworkViewModel vm;

  @override
  Widget build(BuildContext context) {
    final muted = _muted(context);
    final selected = NetworkViewModel.speedTestServers
        .where((s) => s.$2 == vm.speedTestUrl)
        .firstOrNull;
    final mbps = vm.speedTestMbps;
    final latency = vm.speedTestLatency;
    Widget metric(String value, String label) => Column(
      children: [
        Text(
          value,
          style: composeBody(fontSize: 14, fontFamily: OmniFonts.mono, fontWeight: FontWeight.bold),
        ),
        Text(label, style: composeBody(fontSize: 10, color: muted)),
      ],
    );
    return _tabColumn([
      Text(
        "Measures this device's download throughput from a URL. Pick a test server near you (or "
        'one deliberately far away), or point the URL at your own server to test a specific link.',
        style: composeBody(fontSize: 12, color: muted),
      ),
      _menuField<String>(
        context,
        fieldKey: 'network.speedTest.server',
        label: 'Test Server',
        shown: selected?.$1 ?? 'Custom URL',
        options: [for (final (label, url) in NetworkViewModel.speedTestServers) (url, label)],
        onSelected: (url) {
          vm.speedTestUrl = url;
          vm.fieldEdited();
        },
      ),
      _BoundField(
        fieldKey: 'network.speedTest.url',
        label: 'Download URL',
        value: vm.speedTestUrl,
        keyboardType: TextInputType.url,
        onChanged: (v) {
          vm.speedTestUrl = v;
          vm.fieldEdited();
        },
      ),
      OmniCard(
        key: const ValueKey('network.speedTest.gauge'),
        leftAccent: OmniColors.cyan,
        inset: const EdgeInsets.all(16),
        child: SizedBox(
          width: double.infinity,
          child: Column(
            children: [
              Text(
                mbps == null ? '—' : NumberFormat('0.0').format(mbps),
                style: composeBody(
                  fontSize: 44,
                  fontWeight: FontWeight.bold,
                  fontFamily: OmniFonts.mono,
                  color: vm.speedTestRunning ? OmniColors.cyan : OmniColors.green,
                ),
              ),
              Text('Mbps', style: composeBody(fontSize: 13, color: muted)),
              const SizedBox(height: 8),
              Row(
                mainAxisSize: MainAxisSize.min,
                spacing: 20,
                children: [
                  metric(formatBytes(vm.speedTestBytes), 'downloaded'),
                  if (latency != null) metric('${latency.inMilliseconds} ms', 'time to first byte'),
                ],
              ),
            ],
          ),
        ),
      ),
      _actionButton(
        key: const ValueKey('network.speedTest.run'),
        label: 'Start Speed Test',
        busy: vm.speedTestRunning,
        busyLabel: 'Stop',
        color: vm.speedTestRunning ? OmniColors.amber : null,
        onPressed: vm.speedTestUrl.trim().isEmpty
            ? null
            : vm.speedTestRunning
            ? vm.cancelSpeedTest
            : vm.runSpeedTest,
      ),
      if (vm.speedTestError != null)
        Text(
          vm.speedTestError!,
          style: composeBody(fontSize: 13, fontFamily: OmniFonts.mono, color: OmniColors.red),
        ),
    ]);
  }
}

// ── Tunnels ──────────────────────────────────────────────────────────────────────

String _tunnelSummary(PortForward pf) {
  final dest = '${HostDisplay.instance.sensitive(pf.destHost)}:${pf.destPort}';
  return switch (pf.kind) {
    'remote' => '-R ${pf.bindHost}:${pf.bindPort} → $dest',
    'dynamic' => '-D ${pf.bindHost}:${pf.bindPort} (SOCKS5)',
    _ => '-L ${pf.bindHost}:${pf.bindPort} → $dest',
  };
}

class _TunnelsTab extends StatelessWidget {
  const _TunnelsTab({required this.vm});

  final NetworkViewModel vm;

  @override
  Widget build(BuildContext context) {
    final servers = context.watch<AppState>().servers;
    final muted = _muted(context);
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: 10,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'SSH Tunnels',
                  style: composeBody(fontSize: 16, fontWeight: FontWeight.bold),
                ),
              ),
              FilledButton.icon(
                key: const ValueKey('network.tunnels.add'),
                icon: const Icon(Icons.add, size: 18),
                label: const Text('Add'),
                onPressed: servers.isEmpty || !vm.canTunnel
                    ? null
                    : () => _openTunnelEditor(context, vm, servers),
              ),
            ],
          ),
          Text(
            'Local (-L), remote (-R) and dynamic SOCKS (-D) forwards over a saved SSH host. '
            'Tunnels stay up until you stop them or leave the app.',
            style: composeBody(fontSize: 12, color: muted),
          ),
          Expanded(
            // Not a Kotlin state: a build without the SSH forwarder says so rather than offering
            // switches that cannot work.
            child: !vm.canTunnel
                ? Center(
                    key: const ValueKey('network.tunnels.unavailable'),
                    child: Text(
                      'SSH tunnels are not available in this build.',
                      style: TextStyle(color: muted),
                    ),
                  )
                : servers.isEmpty
                ? Center(
                    child: Text('Add an SSH host first.', style: TextStyle(color: muted)),
                  )
                : vm.portForwards.isEmpty
                ? Center(
                    child: Text(
                      'No tunnels yet. Tap Add to create one.',
                      style: TextStyle(color: muted),
                    ),
                  )
                : ListView.separated(
                    key: const ValueKey('network.tunnels.list'),
                    itemCount: vm.portForwards.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 8),
                    itemBuilder: (context, i) =>
                        _TunnelCard(vm: vm, pf: vm.portForwards[i], servers: servers),
                  ),
          ),
        ],
      ),
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
    final muted = _muted(context);
    final active = vm.isTunnelActive(pf.id);
    final busy = vm.isTunnelBusy(pf.id);
    final serverName =
        servers.where((s) => s.id == pf.serverId).firstOrNull?.name ?? '(missing host)';
    final error = vm.tunnelError(pf.id);
    return OmniCard(
      key: ValueKey('network.tunnel.${pf.id}'),
      leftAccent: active ? OmniColors.green : muted,
      inset: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(pf.name, style: composeBody(fontSize: 14, fontWeight: FontWeight.bold)),
                    Text(
                      _tunnelSummary(pf),
                      style: composeBody(fontSize: 12, fontFamily: OmniFonts.mono, color: muted),
                    ),
                    Text('via $serverName', style: composeBody(fontSize: 11, color: muted)),
                  ],
                ),
              ),
              if (busy)
                const SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              else
                Switch(
                  key: ValueKey('network.tunnel.${pf.id}.toggle'),
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
                style: composeBody(fontSize: 11, fontFamily: OmniFonts.mono, color: OmniColors.red),
              ),
            ),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            spacing: 8,
            children: [
              TextButton(
                key: ValueKey('network.tunnel.${pf.id}.edit'),
                onPressed: active ? null : () => _openTunnelEditor(context, vm, servers, pf),
                child: const Text('Edit'),
              ),
              TextButton(
                key: ValueKey('network.tunnel.${pf.id}.delete'),
                onPressed: () async {
                  final confirmed = await showOmniConfirm(
                    context,
                    title: 'Delete "${pf.name}"?',
                    message: "Remove this saved tunnel? If it's running it will be stopped.",
                    confirmLabel: 'Delete',
                    destructive: true,
                    keyPrefix: 'network.tunnel.deleteDialog',
                  );
                  if (confirmed) await vm.deleteTunnel(pf);
                },
                child: const Text('Delete', style: TextStyle(color: OmniColors.red)),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

Future<void> _openTunnelEditor(
  BuildContext context,
  NetworkViewModel vm,
  List<Server> servers, [
  PortForward? existing,
]) => showDialog<void>(
  context: context,
  builder: (_) => _TunnelDialog(vm: vm, servers: servers, existing: existing),
);

/// Kotlin's `TunnelEditorDialog`.
class _TunnelDialog extends StatefulWidget {
  const _TunnelDialog({required this.vm, required this.servers, this.existing});

  final NetworkViewModel vm;
  final List<Server> servers;
  final PortForward? existing;

  @override
  State<_TunnelDialog> createState() => _TunnelDialogState();
}

class _TunnelDialogState extends State<_TunnelDialog> with TextControllersState {
  late final _name = TextEditingController(text: widget.existing?.name ?? '');
  late final _bindHost = TextEditingController(text: widget.existing?.bindHost ?? '127.0.0.1');
  late final _bindPort = TextEditingController(
    text: widget.existing == null ? '' : '${widget.existing!.bindPort}',
  );
  late final _destHost = TextEditingController(text: widget.existing?.destHost ?? '');
  late final _destPort = TextEditingController(
    text: widget.existing == null ? '' : '${widget.existing!.destPort}',
  );
  late String _kind = widget.existing?.kind ?? 'local';
  late int _serverId = widget.existing?.serverId ?? widget.servers.firstOrNull?.id ?? 0;
  late bool _autoStart = widget.existing?.autoStart ?? false;
  String? _error;

  static const _kinds = [
    ('local', 'Local (-L)'),
    ('remote', 'Remote (-R)'),
    ('dynamic', 'Dynamic SOCKS (-D)'),
  ];

  @override
  List<TextEditingController> get textControllers => [
    _name,
    _bindHost,
    _bindPort,
    _destHost,
    _destPort,
  ];

  Future<void> _save() async {
    final existing = widget.existing;
    final isDynamic = _kind == 'dynamic';
    try {
      await widget.vm.saveTunnel(
        PortForwardsCompanion.insert(
          id: existing == null ? const Value.absent() : Value(existing.id),
          serverId: _serverId,
          name: _name.text.trim(),
          kind: Value(_kind),
          bindHost: Value(_bindHost.text.trim().isEmpty ? '127.0.0.1' : _bindHost.text.trim()),
          bindPort: int.parse(_bindPort.text.trim()),
          destHost: Value(isDynamic ? '' : _destHost.text.trim()),
          destPort: Value(isDynamic ? 0 : int.parse(_destPort.text.trim())),
          autoStart: Value(_autoStart),
        ),
      );
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
      return;
    }
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final isDynamic = _kind == 'dynamic';
    final bindPortError = portError(_bindPort.text);
    final destPortError = isDynamic ? null : portError(_destPort.text);
    final destHostError = isDynamic || _destHost.text.trim().isNotEmpty ? null : 'Required';
    final valid =
        _name.text.trim().isNotEmpty &&
        bindPortError == null &&
        destPortError == null &&
        destHostError == null;
    final muted = _muted(context);
    Widget text(
      String key,
      TextEditingController c,
      String label, {
      String? error,
      bool port = false,
    }) => TextField(
      key: ValueKey('tunnelEditor.$key'),
      controller: c,
      keyboardType: port ? TextInputType.number : null,
      inputFormatters: port
          ? [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(5)]
          : null,
      decoration: omniInputDecoration(context, labelText: label, errorText: error),
    );
    return AlertDialog(
      key: const ValueKey('tunnelEditor.dialog'),
      scrollable: true,
      title: Text(widget.existing == null ? 'New tunnel' : 'Edit tunnel'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: 10,
        children: [
          text('name', _name, 'Name'),
          _menuField<String>(
            context,
            fieldKey: 'tunnelEditor.kind',
            label: 'Type',
            shown: _kinds.firstWhere((k) => k.$1 == _kind).$2,
            options: _kinds,
            onSelected: (k) => setState(() => _kind = k),
          ),
          _menuField<int>(
            context,
            fieldKey: 'tunnelEditor.server',
            label: 'SSH host',
            shown:
                widget.servers.where((s) => s.id == _serverId).firstOrNull?.name ?? 'Select host',
            options: [for (final s in widget.servers) (s.id, s.name)],
            onSelected: (id) => setState(() => _serverId = id),
          ),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: 8,
            children: [
              Expanded(
                flex: 14,
                child: text(
                  'bindHost',
                  _bindHost,
                  _kind == 'remote' ? 'Remote bind host' : 'Bind host',
                ),
              ),
              Expanded(
                flex: 10,
                child: text('bindPort', _bindPort, 'Port', error: bindPortError, port: true),
              ),
            ],
          ),
          if (!isDynamic)
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              spacing: 8,
              children: [
                Expanded(
                  flex: 14,
                  child: text('destHost', _destHost, 'Dest host', error: destHostError),
                ),
                Expanded(
                  flex: 10,
                  child: text('destPort', _destPort, 'Port', error: destPortError, port: true),
                ),
              ],
            ),
          Text(switch (_kind) {
            'remote' =>
              'The remote host listens on its bind port and forwards connections back to dest '
                  'host:port reachable from this device.',
            'dynamic' =>
              'Opens a SOCKS5 proxy on the bind host:port; point apps at it to route through '
                  'the SSH host.',
            _ =>
              'This device listens on bind host:port and forwards to dest host:port reachable '
                  'from the SSH host.',
          }, style: composeDialogBody(fontSize: 11, color: muted)),
          Row(
            children: [
              Switch(
                key: const ValueKey('tunnelEditor.autoStart'),
                value: _autoStart,
                onChanged: (v) => setState(() => _autoStart = v),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Start when OmniTerm opens', style: composeDialogBody(fontSize: 13)),
                    Text(
                      'The tunnel remains scoped to the app and stops when OmniTerm closes.',
                      style: composeDialogBody(fontSize: 11, color: muted),
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (_error != null)
            Text(_error!, style: composeDialogBody(fontSize: 12, color: OmniColors.red)),
        ],
      ),
      actions: [
        TextButton(
          key: const ValueKey('tunnelEditor.cancel'),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const ValueKey('tunnelEditor.save'),
          onPressed: valid ? _save : null,
          child: const Text('Save'),
        ),
      ],
    );
  }
}
