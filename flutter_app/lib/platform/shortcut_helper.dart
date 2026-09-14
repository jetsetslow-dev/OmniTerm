import 'package:flutter/services.dart';

import '../data/app_database.dart';

/// Launcher shortcut facade. Unsupported platforms return false and keep the action absent/no-op.
class ShortcutHelper {
  ShortcutHelper({this._channel = const MethodChannel('omniterm/shortcuts')});

  final MethodChannel _channel;

  Future<bool> pinServer(Server server) => _call('pinServer', _server(server));
  Future<bool> pushServer(Server server) => _call('pushServer', _server(server));
  Future<bool> reportServerUsed(int id) => _call('reportServerUsed', {'id': id});
  Future<bool> removeServer(int id) => _call('removeServer', {'id': id});
  Future<bool> removeShare(int id) => _call('removeShare', {'id': id});

  Future<bool> pushSplit(Server first, Server second) => _call('pushSplit', {
    'firstId': first.id,
    'secondId': second.id,
    'firstName': first.name.isEmpty ? first.host : first.name,
    'secondName': second.name.isEmpty ? second.host : second.name,
  });

  Future<bool> pushShare(NetworkShare share) =>
      _call('pushShare', {'id': share.id, 'name': share.name, 'address': share.address});

  Map<String, Object> _server(Server server) => {
    'id': server.id,
    'name': server.name,
    'host': server.host,
  };

  Future<bool> _call(String method, Map<String, Object> arguments) async {
    try {
      return await _channel.invokeMethod<bool>(method, arguments) ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }
}
