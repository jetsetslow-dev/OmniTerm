import 'package:flutter/material.dart';

import '../../data/app_database.dart';
import '../view_model/network_view_model.dart';
import 'omni_confirm.dart';

/// Asks before sending [target] a magic packet, then says whether it went out. The one wake flow,
/// used by Tools → Wake-on-LAN and by an offline host's card, as Kotlin's `confirmAndWake`.
Future<void> confirmAndWake(
  BuildContext context,
  NetworkViewModel network,
  WolTarget target,
) async {
  final confirmed = await showOmniConfirm(
    context,
    title: 'Send wake packet?',
    message: 'Send a Wake-on-LAN magic packet to "${target.name}" (${target.macAddress})?',
    confirmLabel: 'Wake',
    destructive: true,
    keyPrefix: 'network.wol.wakeDialog',
  );
  if (!confirmed || !context.mounted) return;
  final messenger = ScaffoldMessenger.maybeOf(context);
  final message = await network.wake(target);
  messenger?.showSnackBar(SnackBar(content: Text(message)));
}
