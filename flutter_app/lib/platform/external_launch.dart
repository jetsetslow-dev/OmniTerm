import 'dart:async';

import 'package:flutter/services.dart';

import '../domain/external_action_guard.dart';

/// Android launcher/notification intents. Home-widget URIs remain supplied by `home_widget`, but
/// are normalized into the same [ExternalAction] type by the runtime binding.
class ExternalLaunch {
  ExternalLaunch({
    this._methodChannel = const MethodChannel('omniterm/external_launch'),
    EventChannel eventChannel = const EventChannel('omniterm/external_launch/events'),
  }) : _events = eventChannel.receiveBroadcastStream().map(_decode);

  final MethodChannel _methodChannel;
  final Stream<ExternalAction> _events;

  Stream<ExternalAction> get actions => _events;

  Future<List<ExternalAction>> takeInitialActions() async {
    try {
      final raw = await _methodChannel.invokeListMethod<Object?>('takeInitialActions');
      return raw?.map(_decode).toList(growable: false) ?? const [];
    } on MissingPluginException {
      return const [];
    } on PlatformException {
      return const [];
    }
  }

  static ExternalAction _decode(Object? value) {
    final map = Map<Object?, Object?>.from(value! as Map);
    return ExternalAction(
      id: map['id']?.toString() ?? '',
      type: map['type']?.toString() ?? '',
      targetId: (map['targetId'] as num?)?.toInt(),
      secondTargetId: (map['secondId'] as num?)?.toInt(),
      target: map['target']?.toString(),
    );
  }
}
