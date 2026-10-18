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
import '../../navigation.dart';
import '../../theme/colors.dart';
import '../../theme/typography.dart';
import '../../widgets/omni_components.dart';
import '../../widgets/popup_scroll_behavior.dart';

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

  String get _distribution => isPlayStoreDistribution ? 'Play Store' : 'Source Available';

  String get _adId => _device?.advertisingId ?? (isPlayStoreDistribution ? '…' : 'N/A');

  /// Kotlin's `deviceDiagnostics()` plus the Ad ID line it appends on copy. It carries no host
  /// names, addresses or credentials, so it is safe to paste into a public issue.
  String get _diagnostics =>
      'App version: ${_package?.version ?? 'unknown'} (${_package?.buildNumber ?? '?'}), '
      '$_distribution\n'
      'Device: ${_device?.device ?? Platform.operatingSystem}, ${_device?.platform ?? _platformLabel()}\n'
      'ABI: ${_device?.abi ?? 'unknown'}\n'
      'Ad ID: $_adId';

  String _platformLabel() {
    if (kIsWeb) return 'Web';
    return '${Platform.operatingSystem} ${Platform.operatingSystemVersion}';
  }

  String? _linkFeedback;
  String? _diagFeedback;

  /// Hands a URL to the platform browser, saying so when nothing can open it (Kotlin's
  /// "No browser app found.").
  Future<void> _openUrl(String url) async {
    var launched = false;
    try {
      launched = await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    } catch (_) {
      launched = false;
    }
    if (!mounted || launched) return;
    setState(() => _linkFeedback = 'No browser app found.');
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final muted = scheme.onSurfaceVariant;
    Widget fullWidth(Widget child) => SizedBox(width: double.infinity, child: child);

    return ToolScaffold(
      title: 'About OmniTerm',
      keyPrefix: 'about',
      onBack: () => context.read<NavigationController>().navigateTo(Screen.tools),
      child: ScrollConfiguration(
        behavior: const PopupScrollBehavior(popupsOnly: false),
        child: SingleChildScrollView(
          key: const ValueKey('about.list'),
          padding: const EdgeInsets.all(16),
          child: Column(
            spacing: 12,
            children: [
              Icon(Icons.hub, size: 64, color: scheme.primary),
              Text(
                'OmniTerm Terminal Console',
                textAlign: TextAlign.center,
                style: composeBody(fontSize: 20, fontWeight: FontWeight.bold),
              ),
              // The installed binary's real version, so a report names what is actually running.
              Text(
                'Version ${_package?.version ?? '…'}',
                key: const ValueKey('about.version'),
                style: composeBody(fontSize: 12, fontFamily: OmniFonts.mono, color: muted),
              ),
              Text(
                'Build ${_package?.buildNumber ?? '…'}',
                key: const ValueKey('about.build'),
                style: composeBody(
                  fontSize: 11,
                  fontFamily: OmniFonts.mono,
                  color: muted.withValues(alpha: muted.a * 0.6),
                ),
              ),
              Text(
                '$_distribution build. Source available for noncommercial use under the PolyForm '
                'Noncommercial License 1.0.0. OmniTerm connects directly to your hosts and keeps '
                'SSH keys and credentials on-device. There is no OmniTerm account or usage '
                'telemetry. ${isPlayStoreDistribution ? 'Play Store builds may contact Google for billing, consent, ads, and in-app review.' : 'Source builds do not include Google billing, ads, consent, or in-app review services.'}',
                key: const ValueKey('about.privacy'),
                textAlign: TextAlign.center,
                style: composeBody(fontSize: 14, color: muted),
              ),
              const SizedBox(height: 24),
              OmniCard(
                key: const ValueKey('about.source'),
                leftAccent: OmniColors.cyan,
                inset: const EdgeInsets.all(16),
                child: Column(
                  spacing: 10,
                  children: [
                    Text(
                      'Source code & contributions',
                      textAlign: TextAlign.center,
                      style: composeBody(fontWeight: FontWeight.bold),
                    ),
                    Text(
                      'Build from source for noncommercial use, file issues, or contribute on '
                      'GitHub.',
                      textAlign: TextAlign.center,
                      style: composeBody(fontSize: 12, color: muted),
                    ),
                    fullWidth(
                      FilledButton.icon(
                        key: const ValueKey('about.openUrl'),
                        icon: const Icon(Icons.code),
                        label: const Text('View on GitHub'),
                        onPressed: () => _openUrl(AboutScreen.projectUrl),
                      ),
                    ),
                    fullWidth(
                      OutlinedButton.icon(
                        key: const ValueKey('about.privacyPolicy'),
                        icon: const Icon(Icons.privacy_tip),
                        label: const Text('Privacy Policy'),
                        onPressed: () => _openUrl(AboutScreen.privacyUrl),
                      ),
                    ),
                    Text(
                      AboutScreen.projectUrl,
                      textAlign: TextAlign.center,
                      style: composeBody(fontSize: 11, fontFamily: OmniFonts.mono, color: muted),
                    ),
                    if (_linkFeedback != null)
                      Text(
                        _linkFeedback!,
                        key: const ValueKey('about.linkFeedback'),
                        style: composeBody(fontSize: 14, color: const Color(0xFFFF0000)),
                      ),
                  ],
                ),
              ),
              OmniCard(
                key: const ValueKey('about.diagnostics'),
                leftAccent: OmniColors.amber,
                inset: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  spacing: 8,
                  children: [
                    const SectionHeader(title: 'Device & diagnostics'),
                    Divider(height: 1, color: scheme.outline.withValues(alpha: 0.3)),
                    _DiagnosticRow(label: 'App version', value: _package?.version ?? '…'),
                    _DiagnosticRow(label: 'Build', value: _package?.buildNumber ?? '…'),
                    _DiagnosticRow(label: 'Distribution', value: _distribution),
                    _DiagnosticRow(
                      label: 'Device',
                      value: _device?.device ?? Platform.operatingSystem,
                    ),
                    _DiagnosticRow(label: 'Android', value: _device?.platform ?? _platformLabel()),
                    _DiagnosticRow(label: 'ABI', value: _device?.abi ?? 'unknown'),
                    _DiagnosticRow(label: 'Ad ID', value: _adId),
                    const SizedBox(height: 2),
                    fullWidth(
                      OutlinedButton.icon(
                        key: const ValueKey('about.copyDiagnostics'),
                        icon: const Icon(Icons.content_copy),
                        label: const Text('Copy diagnostics'),
                        onPressed: () async {
                          await Clipboard.setData(ClipboardData(text: _diagnostics));
                          if (mounted) {
                            setState(() => _diagFeedback = 'Diagnostics copied to clipboard.');
                          }
                        },
                      ),
                    ),
                    // Not in Kotlin: Play builds that show ads need a consent entry point. Hidden
                    // whenever ads are off, which includes every source build.
                    if (_ads?.enabled == true)
                      fullWidth(
                        OutlinedButton.icon(
                          key: const ValueKey('about.adPrivacy'),
                          icon: const Icon(Icons.ads_click),
                          label: const Text('Ad privacy choices'),
                          onPressed: _ads!.showPrivacyOptions,
                        ),
                      ),
                    if (_diagFeedback != null)
                      Text(
                        _diagFeedback!,
                        key: const ValueKey('about.copied'),
                        style: composeBody(fontSize: 12, color: OmniColors.green),
                      ),
                  ],
                ),
              ),
              _CrashHistoryCard(entries: CrashLog.instance.entries),
            ],
          ),
        ),
      ),
    );
  }
}

/// Kotlin's `DiagnosticRow`: a 96dp label and a monospace value that wraps.
class _DiagnosticRow extends StatelessWidget {
  const _DiagnosticRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      SizedBox(
        width: 96,
        child: Text(
          label,
          style: composeBody(fontSize: 13, color: Theme.of(context).colorScheme.onSurfaceVariant),
        ),
      ),
      Expanded(
        child: Text(value, style: composeBody(fontSize: 13, fontFamily: OmniFonts.mono)),
      ),
    ],
  );
}

/// Kotlin's `CrashHistoryCard`: past crashes recorded on this device, each openable to its full
/// trace and reportable, shareable or copyable. Nothing leaves the device unless the user picks a
/// destination.
class _CrashHistoryCard extends StatefulWidget {
  const _CrashHistoryCard({required this.entries});

  final List<CrashEntry> entries;

  @override
  State<_CrashHistoryCard> createState() => _CrashHistoryCardState();
}

class _CrashHistoryCardState extends State<_CrashHistoryCard> {
  int? _expanded;
  String? _feedback;

  void _say(String message) {
    if (mounted) setState(() => _feedback = message);
  }

  /// Kotlin's `CrashLog.openGitHubIssue`, falling back to the clipboard when no browser answers.
  Future<void> _report(CrashEntry entry) async {
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
    // `launchUrl` can throw as well as return false on a device with no browser.
    var launched = false;
    try {
      launched = await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      launched = false;
    }
    if (launched) return;
    await Clipboard.setData(ClipboardData(text: entry.report));
    _say('No browser found — report copied instead.');
  }

  Future<void> _share(CrashEntry entry, Rect origin) async {
    try {
      await SharePlus.instance.share(
        ShareParams(
          subject: 'OmniTerm crash report',
          text: 'OmniTerm crash report\n\n${redactCrashReport(entry.report)}',
          sharePositionOrigin: origin,
        ),
      );
    } catch (_) {
      _say("Couldn't open share sheet.");
    }
  }

  Future<void> _copy(CrashEntry entry) async {
    await Clipboard.setData(ClipboardData(text: entry.report));
    _say('Report copied to clipboard.');
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final muted = scheme.onSurfaceVariant;
    return OmniCard(
      key: const ValueKey('about.crashHistory'),
      leftAccent: OmniColors.red,
      inset: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 8,
        children: [
          const SectionHeader(title: 'Crash history'),
          Divider(height: 1, color: scheme.outline.withValues(alpha: 0.3)),
          if (widget.entries.isEmpty)
            Text(
              'No crashes recorded. Reports appear here automatically if the app crashes.',
              style: composeBody(fontSize: 12, color: muted),
            )
          else ...[
            Text(
              '${widget.entries.length} recorded. Release traces are obfuscated — keep the '
              'version line so it can be decoded.',
              style: composeBody(fontSize: 11, color: muted),
            ),
            for (var index = 0; index < widget.entries.length; index++)
              _entry(context, widget.entries[index], index),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                key: const ValueKey('about.crashHistory.clear'),
                icon: const Icon(Icons.delete, size: 18),
                label: const Text('Clear history'),
                onPressed: () async {
                  await CrashLog.instance.clear();
                  if (!mounted) return;
                  setState(() {
                    _expanded = null;
                    _feedback = 'Crash history cleared.';
                  });
                },
              ),
            ),
          ],
          if (_feedback != null)
            Text(
              _feedback!,
              key: const ValueKey('about.crashHistory.feedback'),
              style: composeBody(fontSize: 12, color: OmniColors.green),
            ),
        ],
      ),
    );
  }

  Widget _entry(BuildContext context, CrashEntry entry, int index) {
    final scheme = Theme.of(context).colorScheme;
    final muted = scheme.onSurfaceVariant;
    final expanded = _expanded == index;
    const buttonPadding = EdgeInsets.symmetric(horizontal: 8, vertical: 6);
    Widget action(String suffix, IconData icon, String label, void Function(BuildContext) onTap) =>
        Expanded(
          child: Builder(
            builder: (buttonContext) => OutlinedButton.icon(
              key: ValueKey('about.crashHistory.$index.$suffix'),
              style: OutlinedButton.styleFrom(padding: buttonPadding),
              icon: Icon(icon, size: 16),
              label: Text(label, style: const TextStyle(fontSize: 12)),
              onPressed: () => onTap(buttonContext),
            ),
          ),
        );
    return Material(
      color: scheme.surfaceContainerHighest.withValues(alpha: 0.4),
      borderRadius: BorderRadius.circular(8),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        key: ValueKey('about.crashHistory.$index'),
        onTap: () => setState(() => _expanded = expanded ? null : index),
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: 6,
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
                            'en_US',
                          ).format(DateTime.fromMillisecondsSinceEpoch(entry.timeMs)),
                          style: composeBody(fontSize: 11, color: muted),
                        ),
                        Text(
                          entry.headline,
                          maxLines: expanded ? null : 2,
                          overflow: expanded ? null : TextOverflow.ellipsis,
                          style: composeBody(fontSize: 12, fontFamily: OmniFonts.mono),
                        ),
                      ],
                    ),
                  ),
                  Icon(
                    expanded ? Icons.expand_less : Icons.expand_more,
                    color: muted,
                    semanticLabel: expanded ? 'Collapse' : 'Expand',
                  ),
                ],
              ),
              if (expanded) ...[
                SelectableText(
                  entry.report,
                  style: composeBody(fontSize: 10, fontFamily: OmniFonts.mono, color: muted),
                ),
                Row(
                  spacing: 8,
                  children: [
                    action('report', Icons.code, 'Report', (_) => _report(entry)),
                    action('share', Icons.share, 'Share', (buttonContext) {
                      final box = buttonContext.findRenderObject() as RenderBox?;
                      final origin = box == null
                          ? Rect.zero
                          : box.localToGlobal(Offset.zero) & box.size;
                      _share(entry, origin);
                    }),
                    action('copy', Icons.content_copy, 'Copy', (_) => _copy(entry)),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
