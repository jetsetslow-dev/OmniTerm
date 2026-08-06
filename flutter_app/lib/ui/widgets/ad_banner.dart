import 'package:flutter/material.dart';

import '../../platform/license_controller.dart';
import '../theme/colors.dart';

/// Banner ad component, shown only when ads are enabled and not removed by purchase.
class AdBanner extends StatelessWidget {
  const AdBanner({super.key, this.licenseController});

  final LicenseController? licenseController;

  @override
  Widget build(BuildContext context) {
    final controller = licenseController;
    if (controller == null) return const SizedBox.shrink();

    return ValueListenableBuilder<LicenseState>(
      valueListenable: controller.state,
      builder: (context, state, _) {
        if (!state.enabled || state.adsRemoved) {
          return const SizedBox.shrink();
        }

        return Container(
          key: const ValueKey('adBanner.container'),
          margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            color: OmniColors.bg2,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: OmniColors.border),
          ),
          child: Row(
            children: [
              const Icon(
                Icons.star_outline_rounded,
                color: OmniColors.amber,
                size: 20,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  'Support OmniTerm — remove ads with Premium',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: OmniColors.textPrimary,
                      ),
                ),
              ),
              TextButton(
                key: const ValueKey('adBanner.removeAds'),
                onPressed: () => controller.launchAdRemovalPurchase(),
                child: Text(
                  state.adRemovalPrice ?? 'Remove Ads',
                  style: const TextStyle(color: OmniColors.cyan),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
