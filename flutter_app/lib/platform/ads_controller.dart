import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';

@immutable
class AdsState {
  const AdsState({
    this.loading = false,
    this.canRequestAds = false,
    this.privacyOptionsRequired = false,
    this.error,
  });

  final bool loading;
  final bool canRequestAds;
  final bool privacyOptionsRequired;
  final String? error;
}

/// Resolves UMP consent before initializing or requesting any ad.
class AdsController {
  AdsController({required this.enabled});

  final bool enabled;
  final ValueNotifier<AdsState> state = ValueNotifier(const AdsState());
  bool _started = false;
  bool _disposed = false;

  void start() {
    if (!enabled || _started || _disposed) return;
    _started = true;
    state.value = const AdsState(loading: true);
    ConsentInformation.instance.requestConsentInfoUpdate(
      ConsentRequestParameters(),
      () => ConsentForm.loadAndShowConsentFormIfRequired((error) {
        unawaited(_finish(error?.message));
      }),
      (error) => unawaited(_finish(error.message)),
    );
  }

  Future<void> _finish(String? formError) async {
    try {
      final canRequest = await ConsentInformation.instance.canRequestAds();
      final privacy =
          await ConsentInformation.instance.getPrivacyOptionsRequirementStatus() ==
          PrivacyOptionsRequirementStatus.required;
      if (canRequest) {
        const testIds = String.fromEnvironment('ADMOB_TEST_DEVICE_IDS');
        await MobileAds.instance.updateRequestConfiguration(
          RequestConfiguration(
            maxAdContentRating: MaxAdContentRating.g,
            testDeviceIds: testIds
                .split(',')
                .map((value) => value.trim())
                .where((value) => value.isNotEmpty)
                .toList(),
          ),
        );
        await MobileAds.instance.initialize();
      }
      if (_disposed) return;
      state.value = AdsState(
        canRequestAds: canRequest,
        privacyOptionsRequired: privacy,
        error: formError,
      );
    } catch (error) {
      if (!_disposed) {
        state.value = AdsState(error: 'Could not initialize ads: $error');
      }
    }
  }

  Future<void> showPrivacyOptions() async {
    if (!enabled || _disposed) return;
    await ConsentForm.showPrivacyOptionsForm((error) {
      if (error != null && !_disposed) {
        state.value = AdsState(
          canRequestAds: state.value.canRequestAds,
          privacyOptionsRequired: state.value.privacyOptionsRequired,
          error: error.message,
        );
      }
    });
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    state.dispose();
  }
}
