import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

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

  @override
  State<AboutScreen> createState() => _AboutScreenState();
}

class _AboutScreenState extends State<AboutScreen> {
  /// Read from the build rather than hard-coded, so it names the binary that is actually installed.
  /// A version constant edited by hand is the fastest way to make a bug report useless.
  PackageInfo? _package;
  String? _copied;

  @override
  void initState() {
    super.initState();
    _loadVersion();
  }

  Future<void> _loadVersion() async {
    try {
      final info = await PackageInfo.fromPlatform();
      if (mounted) setState(() => _package = info);
    } catch (_) {
      // A missing platform channel (a plain `flutter test` host) must not blank the screen.
    }
  }

  /// What a support request needs, and nothing more.
  ///
  /// Deliberately excludes anything identifying: no host names, no addresses, no usernames. A
  /// diagnostics block a user is invited to paste into a public issue must be safe to paste there.
  String get _diagnostics => [
        'OmniTerm ${_package?.version ?? 'unknown'} (build ${_package?.buildNumber ?? '?'})',
        'Platform: ${_platformLabel()}',
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
    var launched = false;
    try {
      launched = await launchUrl(
        Uri.parse(AboutScreen.projectUrl),
        mode: LaunchMode.externalApplication,
      );
    } catch (_) {
      launched = false;
    }
    if (!mounted || launched) return;
    setState(() => _copied = null);
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      const SnackBar(content: Text('No app could open that link — use Copy link instead.')),
    );
  }

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
              const Text(
                'OmniTerm',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 20),
              ),
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
                'OmniTerm connects straight to the hosts you configure, over SSH and SFTP. '
                'Credentials and private keys are encrypted and stay on this device. There is no '
                'OmniTerm account, no telemetry, and no third-party server between you and your '
                'machines.',
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
            ],
          ),
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
