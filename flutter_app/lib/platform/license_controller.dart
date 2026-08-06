import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:in_app_purchase/in_app_purchase.dart';

/// Product IDs matching Google Play / App Store configuration.
const String omnitermPremiumUnlockId = 'omniterm_premium_unlock';
const String omnitermAdRemovalId = 'omniterm_ad_removal';

/// State of user entitlements and billing products.
@immutable
class LicenseState {
  const LicenseState({
    this.enabled = false,
    this.loading = false,
    this.unlocked = true,
    this.adsRemoved = true,
    this.productPrice,
    this.adRemovalPrice,
    this.message,
  });

  final bool enabled;
  final bool loading;
  final bool unlocked;
  final bool adsRemoved;
  final String? productPrice;
  final String? adRemovalPrice;
  final String? message;

  LicenseState copyWith({
    bool? enabled,
    bool? loading,
    bool? unlocked,
    bool? adsRemoved,
    String? productPrice,
    String? adRemovalPrice,
    String? message,
  }) {
    return LicenseState(
      enabled: enabled ?? this.enabled,
      loading: loading ?? this.loading,
      unlocked: unlocked ?? this.unlocked,
      adsRemoved: adsRemoved ?? this.adsRemoved,
      productPrice: productPrice ?? this.productPrice,
      adRemovalPrice: adRemovalPrice ?? this.adRemovalPrice,
      message: message ?? this.message,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is LicenseState &&
          runtimeType == other.runtimeType &&
          enabled == other.enabled &&
          loading == other.loading &&
          unlocked == other.unlocked &&
          adsRemoved == other.adsRemoved &&
          productPrice == other.productPrice &&
          adRemovalPrice == other.adRemovalPrice &&
          message == other.message;

  @override
  int get hashCode => Object.hash(
        enabled,
        loading,
        unlocked,
        adsRemoved,
        productPrice,
        adRemovalPrice,
        message,
      );
}

/// Abstract controller for licensing and in-app purchases.
abstract interface class LicenseController {
  ValueListenable<LicenseState> get state;
  void start();
  void refresh();
  void onResume();
  Future<void> launchPurchase();
  Future<void> launchAdRemovalPurchase();
  void dispose();
}

/// Disabled / OpenSource fallback controller where everything is unlocked and ads are removed.
class DisabledLicenseController implements LicenseController {
  DisabledLicenseController()
      : _state = ValueNotifier<LicenseState>(const LicenseState(
          enabled: false,
          loading: false,
          unlocked: true,
          adsRemoved: true,
        ));

  final ValueNotifier<LicenseState> _state;

  @override
  ValueListenable<LicenseState> get state => _state;

  @override
  void start() {}

  @override
  void refresh() {}

  @override
  void onResume() {}

  @override
  Future<void> launchPurchase() async {}

  @override
  Future<void> launchAdRemovalPurchase() async {}

  @override
  void dispose() {
    _state.dispose();
  }
}

/// Real InAppPurchase-backed LicenseController implementation.
class InAppLicenseController implements LicenseController {
  InAppLicenseController({InAppPurchase? iap})
      : _iap = iap ?? InAppPurchase.instance,
        _state = ValueNotifier<LicenseState>(const LicenseState(
          enabled: true,
          loading: true,
          unlocked: false,
          adsRemoved: false,
        ));

  final InAppPurchase _iap;
  final ValueNotifier<LicenseState> _state;
  StreamSubscription<List<PurchaseDetails>>? _subscription;
  ProductDetails? _premiumProduct;
  ProductDetails? _adRemovalProduct;
  bool _started = false;

  @override
  ValueListenable<LicenseState> get state => _state;

  @override
  void start() {
    if (_started) return;
    _started = true;
    _subscription = _iap.purchaseStream.listen(
      _onPurchasesUpdated,
      onError: (Object error) {
        _updateState(loading: false, message: 'Billing error: $error');
      },
    );
    connect();
  }

  @override
  void refresh() {
    _updateState(loading: true, message: null);
    connect();
  }

  @override
  void onResume() {
    if (!_started) {
      start();
      return;
    }
    connect();
  }

  Future<void> connect() async {
    try {
      final available = await _iap.isAvailable();
      if (!available) {
        _updateState(
          loading: false,
          message: 'In-app purchases are unavailable on this device.',
        );
        return;
      }
      await _queryProducts();
      await _iap.restorePurchases();
    } catch (e) {
      _updateState(
        loading: false,
        message: 'Could not connect to store: $e',
      );
    }
  }

  Future<void> _queryProducts() async {
    const ids = <String>{omnitermPremiumUnlockId, omnitermAdRemovalId};
    final response = await _iap.queryProductDetails(ids);
    if (response.notFoundIDs.isNotEmpty && response.productDetails.isEmpty) {
      _updateState(
        loading: false,
        message: 'Products not found in store.',
      );
      return;
    }
    for (final details in response.productDetails) {
      if (details.id == omnitermPremiumUnlockId) {
        _premiumProduct = details;
      } else if (details.id == omnitermAdRemovalId) {
        _adRemovalProduct = details;
      }
    }
    _updateState(
      loading: false,
      productPrice: _premiumProduct?.price,
      adRemovalPrice: _adRemovalProduct?.price,
    );
  }

  void _onPurchasesUpdated(List<PurchaseDetails> purchases) {
    var unlocked = _state.value.unlocked;
    var adsRemoved = _state.value.adsRemoved;

    for (final purchase in purchases) {
      if (purchase.status == PurchaseStatus.purchased ||
          purchase.status == PurchaseStatus.restored) {
        if (purchase.productID == omnitermPremiumUnlockId) {
          unlocked = true;
          adsRemoved = true;
        } else if (purchase.productID == omnitermAdRemovalId) {
          adsRemoved = true;
        }
        if (purchase.pendingCompletePurchase) {
          _iap.completePurchase(purchase);
        }
      } else if (purchase.status == PurchaseStatus.error) {
        _updateState(
          loading: false,
          message: purchase.error?.message ?? 'Purchase failed.',
        );
      }
    }

    _updateState(
      loading: false,
      unlocked: unlocked,
      adsRemoved: adsRemoved || unlocked,
    );
  }

  @override
  Future<void> launchPurchase() async {
    final details = _premiumProduct;
    if (details == null) {
      _updateState(message: 'Unlock purchase not available yet.');
      return;
    }
    final param = PurchaseParam(productDetails: details);
    await _iap.buyNonConsumable(purchaseParam: param);
  }

  @override
  Future<void> launchAdRemovalPurchase() async {
    final details = _adRemovalProduct;
    if (details == null) {
      _updateState(message: 'Ad removal purchase not available yet.');
      return;
    }
    final param = PurchaseParam(productDetails: details);
    await _iap.buyNonConsumable(purchaseParam: param);
  }

  void _updateState({
    bool? loading,
    bool? unlocked,
    bool? adsRemoved,
    String? productPrice,
    String? adRemovalPrice,
    String? message,
  }) {
    _state.value = _state.value.copyWith(
      loading: loading,
      unlocked: unlocked,
      adsRemoved: adsRemoved,
      productPrice: productPrice,
      adRemovalPrice: adRemovalPrice,
      message: message,
    );
  }

  @override
  void dispose() {
    _subscription?.cancel();
    _state.dispose();
  }
}
