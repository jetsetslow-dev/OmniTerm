import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:home_widget/home_widget.dart';

import '../data/app_database.dart';

/// Syncs host summaries and quick connection shortcuts to home screen widgets.
class HomeWidgetSync {
  HomeWidgetSync({String? androidWidgetProvider, String? iOSAppGroupId})
      : _androidWidgetProvider = androidWidgetProvider ?? 'OmniTermWidgetReceiver',
        _iOSAppGroupId = iOSAppGroupId ?? 'group.com.jetsetslow.omniterm';

  final String _androidWidgetProvider;
  final String _iOSAppGroupId;

  /// Update widget data for the specified servers.
  Future<bool> updateWidgetData(List<Server> servers) async {
    try {
      if (kIsWeb) return false;
      await HomeWidget.setAppGroupId(_iOSAppGroupId);

      final count = servers.length;
      await HomeWidget.saveWidgetData<int>('server_count', count);

      if (servers.isNotEmpty) {
        final topHost = servers.first;
        await HomeWidget.saveWidgetData<String>('top_server_name', topHost.name);
        await HomeWidget.saveWidgetData<String>('top_server_host', topHost.host);
        await HomeWidget.saveWidgetData<int>('top_server_id', topHost.id);
      }

      await HomeWidget.updateWidget(
        name: _androidWidgetProvider,
        iOSName: 'OmniTermWidget',
      );
      return true;
    } catch (_) {
      // Platform unsupported or home widget update failed.
      return false;
    }
  }

  /// Checks if the app was launched from tapping a home screen widget.
  Future<Uri?> getInitiallyLaunchedUri() async {
    try {
      if (kIsWeb) return null;
      await HomeWidget.setAppGroupId(_iOSAppGroupId);
      return await HomeWidget.initiallyLaunchedFromHomeWidget();
    } catch (_) {
      return null;
    }
  }

  /// Listen for widget taps while the app is already in memory.
  Stream<Uri?> get widgetClickedStream {
    try {
      if (kIsWeb) return const Stream.empty();
      return HomeWidget.widgetClicked;
    } catch (_) {
      return const Stream.empty();
    }
  }
}
