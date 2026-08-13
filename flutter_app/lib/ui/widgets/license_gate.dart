import 'package:flutter/material.dart';

import '../../platform/license_controller.dart';
import '../theme/colors.dart';

Future<void> showPremiumGate(
  BuildContext context, {
  required LicenseController controller,
  required String title,
  required String message,
}) => showModalBottomSheet<void>(
  context: context,
  useSafeArea: true,
  // Scroll-controlled because a sheet is otherwise capped at half the available height: on a
  // small phone in landscape at 200% text that is ~180px, and this content needs far more.
  // The clipped part is the bottom, which is where the buttons are. Parity defects 112-115
  // are the same failure in dialogs.
  isScrollControlled: true,
  builder: (sheetContext) => Padding(
    key: const ValueKey('license.gate'),
    padding: const EdgeInsets.all(24),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Icon(Icons.lock, size: 44, color: OmniColors.amber),
        const SizedBox(height: 14),
        Text(
          title,
          textAlign: TextAlign.center,
          style: Theme.of(sheetContext).textTheme.titleMedium,
        ),
        const SizedBox(height: 8),
        Text(message, textAlign: TextAlign.center),
        const SizedBox(height: 20),
        FilledButton(
          key: const ValueKey('license.gate.unlock'),
          onPressed: () {
            Navigator.pop(sheetContext);
            controller.launchPurchase();
          },
          child: Text(
            controller.state.value.productPrice == null
                ? 'Unlock OmniTerm'
                : 'Unlock ${controller.state.value.productPrice}',
          ),
        ),
      ],
    ),
  ),
);
