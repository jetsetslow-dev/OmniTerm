import 'package:url_launcher/url_launcher.dart';

/// Opens an http(s) link in the app's browser surface or in the user's browser.
Future<bool> openLink(Uri uri, {required bool inApp}) async {
  if (uri.scheme != 'http' && uri.scheme != 'https') return false;
  try {
    return await launchUrl(
      uri,
      mode: inApp ? LaunchMode.inAppBrowserView : LaunchMode.externalApplication,
    );
  } catch (_) {
    return false;
  }
}
