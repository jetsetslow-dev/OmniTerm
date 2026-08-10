import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../platform/ads_controller.dart';
import '../../../platform/crash_log.dart';
import '../../../platform/device_diagnostics.dart';
import '../../../platform/distribution.dart';
import '../../theme/colors.dart';
import '../../theme/typography.dart';
import '../../widgets/omni_components.dart';

/// The About tool, ported from `AboutToolView` in `ui/ToolsScreen.kt`.
///
/// Two jobs: say plainly what the app does with your data, and give a support request enough
/// detail to be actionable. Neither is decoration — the first is the claim the app is asking to be
/// trusted on, and the second is what turns "it doesn't work" into a reproducible report.
class AboutScreen extends StatefulWidget {
  const AboutScreen({super.key});

  static const projectUrl = 'https://github.com/jetsetslow-dev/OmniTerm';
  static const privacyUrl = '$projectUrl/blob/main/PRIVACY.md';

  @override
  State<AboutScreen> createState() => _AboutScreenState();
}

class _AboutScreenState extends State<AboutScreen> {
  /// Read from the build rather than hard-coded, so it names the binary that is actually installed.
  /// A version constant edited by hand is the fastest way to make a bug report useless.
  PackageInfo? _package;
  DeviceDiagnostics? _device;
  String? _copied;
  AdsController? _ads;

  @override
  void initState() {
    super.initState();
    _loadDiagnostics();
    CrashLog.instance.addListener(_onCrashHistoryChanged);
  }

  Future<void> _loadDiagnostics() async {
    try {
      final values = await Future.wait<Object>([
        PackageInfo.fromPlatform(),
        DeviceDiagnostics.load(includeAdvertisingId: isPlayStoreDistribution),
      ]);
      if (mounted) {
        setState(() {
          _package = values[0] as PackageInfo;
          _device = values[1] as DeviceDiagnostics;
        });
      }
    } catch (_) {
      // A missing platform channel (a plain `flutter test` host) must not blank the screen.
    }
  }

  void _onCrashHistoryChanged() {
    if (mounted) setState(() {});
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    try {
      _ads ??= context.read<AdsController>();
    } on ProviderNotFoundException {
      // Isolated widget tests and source-only embeddings may omit the ads provider.
    }
  }

  @override
  void dispose() {
    CrashLog.instance.removeListener(_onCrashHistoryChanged);
    super.dispose();
  }

  /// What a support request needs, and nothing more.
  ///
  /// Deliberately excludes anything identifying: no host names, no addresses, no usernames. A
  /// diagnostics block a user is invited to paste into a public issue must be safe to paste there.
  String get _diagnostics => [
    'OmniTerm ${_package?.version ?? 'unknown'} (build ${_package?.buildNumber ?? '?'})',
    'Distribution: ${isPlayStoreDistribution ? 'Play Store' : 'Source available'}',
    'Device: ${_device?.device ?? Platform.operatingSystem}',
    'Platform: ${_device?.platform ?? _platformLabel()}',
    'ABI: ${_device?.abi ?? 'unknown'}',
    'Ad ID: ${_device?.advertisingId ?? (isPlayStoreDistribution ? '…' : 'N/A')}',
    'Dart: ${Platform.version.split(' ').first}',
  ].join('\n');

  String _platformLabel() {
    if (kIsWeb) return 'Web';
    return '${Platform.operatingSystem} ${Platform.operatingSystemVersion}';
  }

  /// Hands the project URL to the platform browser.
  ///
  /// A refusal is reported rather than swallowed. A button that appears to work and does nothing is
  /// how a user concludes the app is broken, and here the fallback — copy the link — is right there.
  Future<void> _openProject() async {
    await _openUrl(AboutScreen.projectUrl);
  }

  Future<void> _openUrl(String url) async {
    var launched = false;
    try {
      launched = await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    } catch (_) {
      launched = false;
    }
    if (!mounted || launched) return;
    setState(() => _copied = null);
    ScaffoldMessenger.maybeOf(
      context,
    )?.showSnackBar(const SnackBar(content: Text('No app could open that link.')));
  }

  Future<void> _reportCrash(CrashEntry entry) async {
    final headline = entry.headline;
    final uri = Uri.parse('${AboutScreen.projectUrl}/issues/new').replace(
      queryParameters: {
        'title': 'Crash: ${headline.substring(0, headline.length.clamp(0, 120))}',
        'body':
            '**Describe what you were doing when this happened:**\n\n\n---\n'
            'Crash:\n```\n$headline\n```\n\n'
            '_Attach the full report via Share on the crash history screen._',
      },
    );
    if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
      await _copy('Crash report', entry.report);
    }
  }

  Future<void> _shareCrash(CrashEntry entry, Rect origin) => SharePlus.instance.share(
    ShareParams(
      subject: 'OmniTerm crash report',
      text: 'OmniTerm crash report\n\n${redactCrashReport(entry.report)}',
      sharePositionOrigin: origin,
    ),
  );

  Future<void> _copy(String label, String text) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    setState(() => _copied = label);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return ListView(
      key: const ValueKey('about.list'),
      padding: const EdgeInsets.all(16),
      children: [
        Center(
          child: Column(
            children: [
              Icon(Icons.hub, size: 56, color: scheme.primary),
              const SizedBox(height: 10),
              const Text('OmniTerm', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 20)),
              Text(
                'Terminal and homelab console',
                style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
              ),
              const SizedBox(height: 8),
              SelectionArea(
                child: Text(
                  _package == null
                      ? 'Version …'
                      : 'Version ${_package!.version} · build ${_package!.buildNumber}',
                  key: const ValueKey('about.version'),
                  style: TextStyle(
                    fontSize: 12,
                    fontFamily: OmniFonts.mono,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),
        OmniCard(
          key: const ValueKey('about.privacy'),
          leftAccent: OmniColors.green,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Where your data goes',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
              ),
              const SizedBox(height: 6),
              Text(
                // The specific claims, not a vague reassurance — each is checkable against the
                // source, which is the only reason a statement like this is worth anything.
                'OmniTerm connects straight to the hosts you configure. Credentials and private '
                'keys are encrypted and stay on this device. There is no OmniTerm account or '
                'usage telemetry. ${isPlayStoreDistribution ? 'Play Store builds may contact Google for billing, consent, and ads.' : 'Source builds do not include billing or ads.'}',
                style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        OmniCard(
          key: const ValueKey('about.source'),
          leftAccent: OmniColors.cyan,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Source and licence',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
              ),
              const SizedBox(height: 6),
              Text(
                'Source available for noncommercial use under the PolyForm Noncommercial '
                'License 1.0.0.',
                style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
              ),
              const SizedBox(height: 8),
              SelectionArea(
                child: Text(
                  AboutScreen.projectUrl,
                  style: const TextStyle(fontSize: 11, fontFamily: OmniFonts.mono),
                ),
              ),
              const SizedBox(height: 6),
              Row(
                children: [
                  OutlinedButton.icon(
                    key: const ValueKey('about.openUrl'),
                    icon: const Icon(Icons.open_in_new, size: 16),
                    label: const Text('Open', style: TextStyle(fontSize: 12)),
                    onPressed: _openProject,
                  ),
                  const SizedBox(width: 8),
                  // Copy stays alongside Open rather than being replaced by it: a device with no
                  // browser, or a launch the platform refuses, must still leave a way to get the
                  // address off the screen.
                  OutlinedButton.icon(
                    key: const ValueKey('about.copyUrl'),
                    icon: const Icon(Icons.copy, size: 16),
                    label: const Text('Copy link', style: TextStyle(fontSize: 12)),
                    onPressed: () => _copy('Link', AboutScreen.projectUrl),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  key: const ValueKey('about.privacyPolicy'),
                  icon: const Icon(Icons.privacy_tip, size: 16),
                  label: const Text('Privacy policy', style: TextStyle(fontSize: 12)),
                  onPressed: () => _openUrl(AboutScreen.privacyUrl),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        OmniCard(
          key: const ValueKey('about.diagnostics'),
          leftAccent: OmniColors.amber,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Diagnostics',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
              ),
              const SizedBox(height: 6),
              Text(
                // Saying what it does *not* contain, so a user can paste it into a public issue
                // without having to audit it first.
                'Include this in a bug report. It carries no host names, addresses or credentials.',
                style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
              ),
              const SizedBox(height: 8),
              _DiagnosticRow(label: 'App version', value: _package?.version ?? '…'),
              _DiagnosticRow(label: 'Build', value: _package?.buildNumber ?? '…'),
              _DiagnosticRow(
                label: 'Distribution',
                value: isPlayStoreDistribution ? 'Play Store' : 'Source available',
              ),
              _DiagnosticRow(label: 'Device', value: _device?.device ?? Platform.operatingSystem),
              _DiagnosticRow(label: 'Platform', value: _device?.platform ?? _platformLabel()),
              _DiagnosticRow(label: 'ABI', value: _device?.abi ?? 'unknown'),
              _DiagnosticRow(
                label: 'Ad ID',
                value: _device?.advertisingId ?? (isPlayStoreDistribution ? '…' : 'N/A'),
              ),
              const SizedBox(height: 4),
              SelectionArea(
                child: Text(
                  _diagnostics,
                  key: const ValueKey('about.diagnostics.text'),
                  style: const TextStyle(fontSize: 11, fontFamily: OmniFonts.mono),
                ),
              ),
              const SizedBox(height: 6),
              OutlinedButton.icon(
                key: const ValueKey('about.copyDiagnostics'),
                icon: const Icon(Icons.copy, size: 16),
                label: const Text('Copy diagnostics', style: TextStyle(fontSize: 12)),
                onPressed: () => _copy('Diagnostics', _diagnostics),
              ),
              if (_ads?.enabled == true) ...[
                const SizedBox(height: 6),
                OutlinedButton.icon(
                  key: const ValueKey('about.adPrivacy'),
                  icon: const Icon(Icons.ads_click, size: 16),
                  label: const Text('Ad privacy choices', style: TextStyle(fontSize: 12)),
                  onPressed: _ads!.showPrivacyOptions,
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 12),
        _CrashHistoryCard(
          entries: CrashLog.instance.entries,
          onReport: _reportCrash,
          onShare: _shareCrash,
          onCopy: (entry) => _copy('Crash report', entry.report),
          onClear: CrashLog.instance.clear,
        ),
        if (_copied != null)
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Text(
              '$_copied copied to the clipboard.',
              key: const ValueKey('about.copied'),
              style: const TextStyle(fontSize: 12, color: OmniColors.green),
            ),
          ),
      ],
    );
  }
}

class _DiagnosticRow extends StatelessWidget {
  const _DiagnosticRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 2),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 96,
          child: Text(
            label,
            style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant),
          ),
        ),
        Expanded(
          child: Text(value, style: const TextStyle(fontSize: 12, fontFamily: OmniFonts.mono)),
        ),
      ],
    ),
  );
}

class _CrashHistoryCard extends StatefulWidget {
  const _CrashHistoryCard({
    required this.entries,
    required this.onReport,
    required this.onShare,
    required this.onCopy,
    required this.onClear,
  });

  final List<CrashEntry> entries;
  final Future<void> Function(CrashEntry entry) onReport;
  final Future<void> Function(CrashEntry entry, Rect origin) onShare;
  final Future<void> Function(CrashEntry entry) onCopy;
  final Future<void> Function() onClear;

  @override
  State<_CrashHistoryCard> createState() => _CrashHistoryCardState();
}

class _CrashHistoryCardState extends State<_CrashHistoryCard> {
  int? _expanded;

  @override
  Widget build(BuildContext context) => OmniCard(
    key: const ValueKey('about.crashHistory'),
    leftAccent: OmniColors.red,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Crash history', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
        const Divider(),
        if (widget.entries.isEmpty)
          Text(
            'No crashes recorded. Reports appear here and remain on this device.',
            style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant),
          )
        else ...[
          Text(
            '${widget.entries.length} recorded. Release traces may be obfuscated; keep the '
            'version line so they can be decoded.',
            style: TextStyle(fontSize: 11, color: Theme.of(context).colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 8),
          for (var index = 0; index < widget.entries.length; index++)
            _entry(context, widget.entries[index], index),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              key: const ValueKey('about.crashHistory.clear'),
              icon: const Icon(Icons.delete, size: 17),
              label: const Text('Clear history'),
              onPressed: () async {
                await widget.onClear();
                if (mounted) setState(() => _expanded = null);
              },
            ),
          ),
        ],
      ],
    ),
  );

  Widget _entry(BuildContext context, CrashEntry entry, int index) {
    final expanded = _expanded == index;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          key: ValueKey('about.crashHistory.$index'),
          borderRadius: BorderRadius.circular(8),
          onTap: () => setState(() => _expanded = expanded ? null : index),
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.bug_report, color: OmniColors.red, size: 18),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            DateFormat(
                              'yyyy-MM-dd HH:mm',
                            ).format(DateTime.fromMillisecondsSinceEpoch(entry.timeMs)),
                            style: TextStyle(
                              fontSize: 11,
                              color: Theme.of(context).colorScheme.onSurfaceVariant,
                            ),
                          ),
                          Text(
                            entry.headline,
                            maxLines: expanded ? null : 2,
                            overflow: expanded ? null : TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 11, fontFamily: OmniFonts.mono),
                          ),
                        ],
                      ),
                    ),
                    Icon(expanded ? Icons.expand_less : Icons.expand_more),
                  ],
                ),
                if (expanded) ...[
                  const SizedBox(height: 8),
                  SelectableText(
                    entry.report,
                    style: const TextStyle(fontSize: 10, fontFamily: OmniFonts.mono),
                  ),
                  const SizedBox(height: 8),
                  Builder(
                    builder: (buttonContext) => Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      children: [
                        OutlinedButton(
                          key: ValueKey('about.crashHistory.$index.report'),
                          onPressed: () => widget.onReport(entry),
                          child: const Text('Report'),
                        ),
                        OutlinedButton(
                          key: ValueKey('about.crashHistory.$index.share'),
                          onPressed: () {
                            final box = buttonContext.findRenderObject() as RenderBox?;
                            final origin = box == null
                                ? Rect.zero
                                : box.localToGlobal(Offset.zero) & box.size;
                            widget.onShare(entry, origin);
                          },
                          child: const Text('Share'),
                        ),
                        OutlinedButton(
                          key: ValueKey('about.crashHistory.$index.copy'),
                          onPressed: () => widget.onCopy(entry),
                          child: const Text('Copy'),
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
