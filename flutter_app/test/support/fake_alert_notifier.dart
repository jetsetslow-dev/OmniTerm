import 'package:omniterm/domain/alert_notification.dart';
import 'package:omniterm/platform/alert_notifier.dart';

/// An [AlertNotifier] that records instead of reaching the notification shade.
class FakeAlertNotifier implements AlertNotifier {
  FakeAlertNotifier({this.permission = true});

  bool permission;
  int permissionRequests = 0;

  final List<AlertNotification> posted = [];
  final List<int> cleared = [];

  /// When set, `post` throws it — the "the platform refused" path.
  Object? postFailure;

  @override
  Future<bool> ensurePermission() async {
    permissionRequests++;
    return permission;
  }

  @override
  Future<void> post(AlertNotification notification) async {
    final failure = postFailure;
    if (failure != null) throw failure;
    posted.add(notification);
  }

  @override
  Future<void> clear(int id) async => cleared.add(id);
}
