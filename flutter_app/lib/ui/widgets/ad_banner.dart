import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';

import '../../platform/ads_controller.dart';
import '../../platform/license_controller.dart';
import '../theme/colors.dart';

const _androidTestBanner = 'ca-app-pub-3940256099942544/6300978111';
const _iosTestBanner = 'ca-app-pub-3940256099942544/2934735716';

/// One consent-gated anchored adaptive banner, matching the Play Store Kotlin flavor.
class AdBanner extends StatelessWidget {
  const AdBanner({super.key, this.licenseController, this.adsController});

  final LicenseController? licenseController;
  final AdsController? adsController;

  @override
  Widget build(BuildContext context) {
    final license = licenseController;
    if (license == null) return const SizedBox.shrink();
    return ValueListenableBuilder<LicenseState>(
      valueListenable: license.state,
      builder: (context, state, _) {
        if (!state.enabled || state.adsRemoved) return const SizedBox.shrink();
        final ads = adsController;
        // Tests and unsupported targets do not have an ads plugin. Production supplies the
        // controller and never substitutes this purchase card for an advertisement.
        if (ads == null) {
          return _AdFallback(license: license, price: state.adRemovalPrice);
        }
        return ValueListenableBuilder<AdsState>(
          valueListenable: ads.state,
          builder: (context, adState, _) {
            if (!adState.canRequestAds) {
              return kDebugMode && adState.loading
                  ? const Text(
                      '[ads: awaiting consent — no request yet]',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 10),
                    )
                  : const SizedBox.shrink();
            }
            return const _AdaptiveBanner();
          },
        );
      },
    );
  }
}

class _AdaptiveBanner extends StatefulWidget {
  const _AdaptiveBanner();

  @override
  State<_AdaptiveBanner> createState() => _AdaptiveBannerState();
}

class _AdaptiveBannerState extends State<_AdaptiveBanner> {
  BannerAd? _ad;
  int? _loadedWidth;

  String get _unitId {
    const configured = String.fromEnvironment('ADMOB_BANNER_UNIT_ID');
    if (configured.isNotEmpty) return configured;
    return defaultTargetPlatform == TargetPlatform.iOS ? _iosTestBanner : _androidTestBanner;
  }

  Future<void> _load(int width) async {
    if (_loadedWidth == width) return;
    _loadedWidth = width;
    final size = await AdSize.getLargeAnchoredAdaptiveBannerAdSize(width);
    if (size == null || !mounted || _loadedWidth != width) return;
    await _ad?.dispose();
    final ad = BannerAd(
      size: size,
      adUnitId: _unitId,
      request: const AdRequest(),
      listener: BannerAdListener(
        onAdLoaded: (loaded) {
          if (!mounted || !identical(loaded, _ad)) return;
          setState(() {});
        },
        onAdFailedToLoad: (failed, _) {
          failed.dispose();
          if (identical(failed, _ad)) _ad = null;
          if (mounted) setState(() {});
        },
      ),
    );
    _ad = ad;
    await ad.load();
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final width = constraints.maxWidth.floor().clamp(320, 4096);
      if (_loadedWidth != width) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _load(width));
      }
      final ad = _ad;
      if (ad == null) return const SizedBox.shrink();
      return SizedBox(
        key: const ValueKey('adBanner.container'),
        width: ad.size.width.toDouble(),
        height: ad.size.height.toDouble(),
        child: AdWidget(ad: ad),
      );
    },
  );

  @override
  void dispose() {
    _ad?.dispose();
    super.dispose();
  }
}

class _AdFallback extends StatelessWidget {
  const _AdFallback({required this.license, required this.price});

  final LicenseController license;
  final String? price;

  @override
  Widget build(BuildContext context) => Container(
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
        const Expanded(child: Text('Support OmniTerm — remove ads')),
        TextButton(
          key: const ValueKey('adBanner.removeAds'),
          onPressed: license.launchAdRemovalPurchase,
          child: Text(price ?? 'Remove Ads'),
        ),
      ],
    ),
  );
}
