import 'package:flutter/foundation.dart';

@immutable
class AddServerRequest {
  const AddServerRequest({this.host, this.suggestedName, this.port = 22});

  final String? host;
  final String? suggestedName;
  final int port;
}

/// One-shot UI requests whose destination widget may not be mounted when an external intent lands.
class ExternalUiRequests extends ChangeNotifier {
  final List<AddServerRequest> _addServerRequests = [];

  bool get hasAddServerRequest => _addServerRequests.isNotEmpty;

  void requestAddServer({String? host, String? suggestedName, int port = 22}) {
    _addServerRequests.add(AddServerRequest(host: host, suggestedName: suggestedName, port: port));
    notifyListeners();
  }

  AddServerRequest? takeAddServerRequest() {
    if (_addServerRequests.isEmpty) return null;
    return _addServerRequests.removeAt(0);
  }
}
