import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../domain/alert_notification.dart';

/// Posts and clears fired-alert notifications.
///
/// The point of an alert is that it reaches the user **without the app open**; a rule that only
/// changes a colour on a screen nobody is looking at has not alerted anybody. This is the piece that
/// makes the Alerts screen more than a dashboard.
///
/// An interface so the view model depends on something injectable: alert evaluation is worth testing
/// without a notification service attached, and a build with none must degrade to "the rule still
/// fires, you just do not get a banner" rather than crashing (Convention 4).
abstract interface class AlertNotifier {
  /// Ask for permission if the platform requires it. Returns whether notifications can be posted.
  Future<bool> ensurePermission();

  Future<void> post(AlertNotification notification);

  /// Clear a previously posted alert, by the same stable id.
  Future<void> clear(int id);
}

/// The real implementation, on `flutter_local_notifications`.
class LocalAlertNotifier implements AlertNotifier {
  LocalAlertNotifier({FlutterLocalNotificationsPlugin? plugin})
    : _plugin = plugin ?? FlutterLocalNotificationsPlugin();

  final FlutterLocalNotificationsPlugin _plugin;

  /// Distinct from the background-session channel, so a user can silence long-running session
  /// notices without also silencing the thing that wakes them when a disk fills up.
  static const channelId = 'omniterm_alerts';
  static const channelName = 'Monitoring alerts';

  bool _initialised = false;

  Future<void> _init() async {
    if (_initialised) return;
    await _plugin.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('ic_stat_omniterm'),
        iOS: DarwinInitializationSettings(
          // Requested explicitly at the point the user turns alerts on, not silently at launch,
          // so the system prompt arrives with context rather than out of nowhere.
          requestAlertPermission: false,
          requestBadgePermission: false,
          requestSoundPermission: false,
        ),
      ),
    );
    _initialised = true;
  }

  @override
  Future<bool> ensurePermission() async {
    await _init();
    try {
      final android = _plugin
          .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
      if (android != null) {
        return await android.requestNotificationsPermission() ?? false;
      }
      final darwin = _plugin
          .resolvePlatformSpecificImplementation<IOSFlutterLocalNotificationsPlugin>();
      if (darwin != null) {
        return await darwin.requestPermissions(alert: true, sound: true, badge: true) ?? false;
      }
    } catch (_) {
      // A platform that cannot be asked is a platform that cannot notify. Reported as false so the
      // caller can say so, rather than posting into a void.
      return false;
    }
    return false;
  }

  @override
  Future<void> post(AlertNotification notification) async {
    await _init();
    try {
      await _plugin.show(
        id: notification.id,
        title: notification.title,
        body: notification.body,
        notificationDetails: const NotificationDetails(
          android: AndroidNotificationDetails(
            channelId,
            channelName,
            // High, and categorised as an alarm: this exists to interrupt. A rule the user set to
            // watch a production disk is not a "quietly in the shade" event.
            importance: Importance.high,
            priority: Priority.high,
            category: AndroidNotificationCategory.alarm,
            autoCancel: true,
          ),
          iOS: DarwinNotificationDetails(interruptionLevel: InterruptionLevel.timeSensitive),
        ),
      );
    } catch (_) {
      // A failed post must never take down the evaluation that raised it: the incident is already
      // recorded, and losing the banner is better than losing the alert.
    }
  }

  @override
  Future<void> clear(int id) async {
    await _init();
    try {
      await _plugin.cancel(id: id);
    } catch (_) {
      // Same reasoning: a stale banner is a nuisance, a crash while resolving an incident is not.
    }
  }
}
