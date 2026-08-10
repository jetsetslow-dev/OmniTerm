import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:home_widget/home_widget.dart';

import '../data/app_database.dart';
import '../domain/widget_payload.dart';

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
      // Written first and cleared to `ok` only once everything else has landed, so a sync that
      // dies part-way leaves the widget saying it could not load rather than showing half a fleet.
      await HomeWidget.saveWidgetData<String>(
        widgetStatusKey,
        widgetStatusFailed,
      );
      await HomeWidget.saveWidgetData<int>('server_count', count);
      await HomeWidget.saveWidgetData<int>(
        'online_count',
        servers.where((server) => server.status == 'online').length,
      );
      await HomeWidget.saveWidgetData<String>(
        'servers_json',
        jsonEncode([
          for (final server in servers)
            {
              'id': server.id,
              'name': server.name,
              'host': server.host,
              'status': server.status,
              'health': server.healthScore,
            },
        ]),
      );

      if (servers.isNotEmpty) {
        final topHost = servers.first;
        await HomeWidget.saveWidgetData<String>('top_server_name', topHost.name);
        await HomeWidget.saveWidgetData<String>('top_server_host', topHost.host);
        await HomeWidget.saveWidgetData<int>('top_server_id', topHost.id);
      } else {
        await HomeWidget.saveWidgetData<String>('top_server_name', null);
        await HomeWidget.saveWidgetData<String>('top_server_host', null);
        await HomeWidget.saveWidgetData<int>('top_server_id', null);
      }

      // Marked good only after every value is written. Until this line the widget treats the
      // payload as unavailable, which is the truth while a sync is part-way through.
      await HomeWidget.saveWidgetData<String>(widgetStatusKey, widgetStatusOk);
      await HomeWidget.updateWidget(name: _androidWidgetProvider, iOSName: 'OmniTermWidget');
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
