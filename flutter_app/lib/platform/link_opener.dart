import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

/// The platform half, split out so a test can drive [openLink] without an Android engine.
@visibleForTesting
const linkOpenerChannel = MethodChannel('omniterm/custom_tabs');

/// Opens an http(s) link in the app's browser surface or in the user's browser.
///
/// Android goes through `CustomTabsBridge`, which is a port of `ui/LinkOpener.kt`. `url_launcher`
/// cannot reproduce it: `InAppBrowserConfiguration` exposes only `showTitle`, so the Custom Tab
/// cannot be tinted to the app's theme, and where no Custom Tabs provider exists url_launcher opens
/// its own bundled WebView while Kotlin hands the link to the user's real browser.
///
/// [toolbarColor] is an ARGB value — Kotlin passes `MaterialTheme.colorScheme.surface`
/// (`ui/ShellScreen.kt:1846`), so callers pass the same role from their own theme. It is ignored for
/// an external open, and on any platform without the bridge.
///
/// Everywhere else — iOS, desktop, tests — falls back to `url_launcher` with the one option it does
/// have. A missing bridge must degrade to opening the link, never to refusing it.
Future<bool> openLink(Uri uri, {required bool inApp, int? toolbarColor}) async {
  if (uri.scheme != 'http' && uri.scheme != 'https') return false;
  try {
    final opened = await linkOpenerChannel.invokeMethod<bool>('open', {
      'url': uri.toString(),
      'inApp': inApp,
      'toolbarColor': ?toolbarColor,
    });
    if (opened != null) return opened;
  } on MissingPluginException {
    // No bridge on this platform; the launcher below is the whole implementation there.
  } on PlatformException {
    return false;
  }

  try {
    return await launchUrl(
      uri,
      mode: inApp ? LaunchMode.inAppBrowserView : LaunchMode.externalApplication,
      // Kotlin's Custom Tab sets `setShowTitle(true)` (`ui/LinkOpener.kt:24`), so the page's title
      // sits above the URL rather than the bare address.
      browserConfiguration: const BrowserConfiguration(showTitle: true),
    );
  } catch (_) {
    return false;
  }
}
