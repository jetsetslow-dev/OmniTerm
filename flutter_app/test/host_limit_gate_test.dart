import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:drift/native.dart';
import 'package:omniterm/data/app_database.dart';
import 'package:omniterm/data/app_repository.dart';
import 'package:omniterm/platform/license_controller.dart';
import 'package:omniterm/platform/secret_store.dart';
import 'package:omniterm/ui/view_model/app_state.dart';
import 'package:omniterm/ui/view_model/servers_view_model.dart';
import 'package:omniterm/ui/widgets/host_limit_gate.dart';
import 'package:provider/provider.dart';

import 'ad_banner_test.dart' show MockTestLicenseController;
import 'servers_view_model_test.dart' show hostFixture;
import 'support/fake_secure_storage.dart';

/// The reconciliation surface for an install already over its host limit.
///
/// Ported from `HostLimitReconciliationDialog` (`ui/AppUi.kt:1286`). The view-model half is covered
/// in `servers_view_model_test.dart`; this is about what the user is shown and what they can do.
///
/// **The gate's rendering path cannot be reached from the host suite**: `isPlayStoreDistribution`
/// is a compile-time constant and these tests build source-available. What is asserted here is that
/// the gate stays out of that build entirely, even with the entitlement claiming otherwise and hosts
/// over the limit.
void main() {
  late AppDatabase db;
  late AppRepository repo;
  late AppState app;
  late ServersViewModel vm;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    repo = AppRepository(db, SecretStore(storage: FakeSecureStorage(<String, String>{})));
    app = AppState(repo);
    vm = ServersViewModel(app);
  });

  tearDown(() async {
    vm.dispose();
    app.dispose();
    await db.close();
  });

  Future<void> pump(WidgetTester tester, LicenseState state) async {
    await app.start();
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<AppState>.value(value: app),
          ChangeNotifierProvider<ServersViewModel>.value(value: vm),
          Provider<LicenseController?>.value(value: MockTestLicenseController(state)),
        ],
        child: const MaterialApp(home: Scaffold(body: HostLimitGate())),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('the source-available build never shows it', (tester) async {
    // The one thing a host-suite widget test can honestly assert here. `isPlayStoreDistribution` is
    // a compile-time constant and these tests build source-available, so every *other* branch would
    // pass on the early return regardless of what it was given — three such tests were written
    // first, all green, none able to fail. The branch coverage lives in `host_limit_test.dart`
    // against `shouldReconcileHostLimit`, where each guard is proved to discriminate.
    await repo.insertServer(hostFixture(name: 'a'));
    await repo.insertServer(hostFixture(name: 'b'));
    await pump(tester, const LicenseState(enabled: true, loading: false, unlocked: false));

    expect(find.byKey(const ValueKey('hostLimit.gate')), findsNothing);
  });
}
