import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../domain/host_display.dart';
import '../../domain/host_limit.dart';
import '../../platform/distribution.dart';
import '../../platform/license_controller.dart';
import '../theme/colors.dart';
import '../theme/typography.dart';
import '../view_model/servers_view_model.dart';

/// Forces a choice when the install holds more saved hosts than its entitlement allows.
///
/// Ported from `HostLimitReconciliationDialog` (`ui/AppUi.kt:1169`, `:1286`).
///
/// **Not dismissible, and that is the point.** A restore on an older build, a lapsed unlock or a
/// refund can all leave hosts saved that the free tier does not cover, and every other route into
/// this state is already blocked — so the only way out is for the user to say which to keep. A
/// dialog that could be waved away would leave the limit permanently unenforced.
///
/// Renders nothing at all when there is no violation, which is every unlocked install and the whole
/// source-available build.
class HostLimitGate extends StatefulWidget {
  const HostLimitGate({super.key});

  @override
  State<HostLimitGate> createState() => _HostLimitGateState();
}

class _HostLimitGateState extends State<HostLimitGate> {
  /// Whether an unlocked entitlement has been seen while this widget has been alive.
  ///
  /// The only way to tell "your unlock ended" from "this build is free" — `LicenseState` carries no
  /// history. Kotlin detects the same transition the same way, in memory
  /// (`updateLicenseEntitlement`'s `wasUnlimited`), so an install that starts already lapsed gets
  /// the plainer free-tier wording in both. That is a limitation the two share rather than a
  /// divergence introduced here.
  bool _sawUnlocked = false;

  @override
  Widget build(BuildContext context) {
    final license = context.read<LicenseController?>();
    if (license == null || !isPlayStoreDistribution) {
      return const SizedBox.shrink();
    }
    return ValueListenableBuilder<LicenseState>(
      valueListenable: license.state,
      builder: (context, state, _) {
        final vm = context.watch<ServersViewModel>();
        if (state.unlocked) _sawUnlocked = true;
        if (!shouldReconcileHostLimit(
          playStoreBuild: isPlayStoreDistribution,
          licenseEnabled: state.enabled,
          licenseLoading: state.loading,
          unlocked: state.unlocked,
          hostLimit: ServersViewModel.freePlayStoreLimit,
          hostCount: vm.servers.length,
        )) {
          return const SizedBox.shrink();
        }
        return _ReconciliationSheet(
          vm: vm,
          reason: _sawUnlocked
              ? HostLimitReason.unlockEnded
              : HostLimitReason.freeTier,
        );
      },
    );
  }
}

class _ReconciliationSheet extends StatefulWidget {
  const _ReconciliationSheet({required this.vm, required this.reason});

  final ServersViewModel vm;
  final HostLimitReason reason;

  @override
  State<_ReconciliationSheet> createState() => _ReconciliationSheetState();
}

class _ReconciliationSheetState extends State<_ReconciliationSheet> {
  final Set<int> _keep = {};

  static const _limit = ServersViewModel.freePlayStoreLimit;

  bool get _valid =>
      isValidHostKeepSelection(selectedCount: _keep.length, hostLimit: _limit);

  Future<void> _apply() async {
    final removed = await widget.vm.reconcileHostLimit(Set.of(_keep));
    if (!mounted || removed == 0) return;
    setState(_keep.clear);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final servers = widget.vm.servers;

    return Material(
      key: const ValueKey('hostLimit.gate'),
      color: Colors.black.withValues(alpha: 0.88),
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Choose which host to keep',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: scheme.onSurface,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  widget.reason.message(_limit),
                  key: const ValueKey('hostLimit.reason'),
                  style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
                ),
                const SizedBox(height: 4),
                const Text(
                  // Said before the deletion, not in a toast after it.
                  'The hosts you do not keep will be deleted from this device, along with '
                  'everything that referenced them.',
                  style: TextStyle(fontSize: 11, color: OmniColors.red),
                ),
                const SizedBox(height: 12),
                for (final server in servers)
                  CheckboxListTile(
                    key: ValueKey('hostLimit.host.${server.id}'),
                    dense: true,
                    controlAffinity: ListTileControlAffinity.leading,
                    title: Text(
                      server.name,
                      style: const TextStyle(fontSize: 13),
                    ),
                    subtitle: Text(
                      HostDisplay.instance.host(server),
                      style: const TextStyle(
                        fontSize: 10,
                        fontFamily: OmniFonts.mono,
                      ),
                    ),
                    value: _keep.contains(server.id),
                    // Only the boxes that would go over are disabled, so a choice can be swapped.
                    onChanged: _valid && !_keep.contains(server.id)
                        ? null
                        : (value) => setState(() {
                            value == true
                                ? _keep.add(server.id)
                                : _keep.remove(server.id);
                          }),
                  ),
                const SizedBox(height: 12),
                FilledButton(
                  key: const ValueKey('hostLimit.confirm'),
                  onPressed: _valid ? _apply : null,
                  child: Text(
                    'Keep ${_keep.length} of ${servers.length}, delete the rest',
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
