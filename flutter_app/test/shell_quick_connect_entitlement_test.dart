import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omniterm/data/app_database.dart';
import 'package:omniterm/data/app_repository.dart';
import 'package:omniterm/platform/license_controller.dart';
import 'package:omniterm/platform/secret_store.dart';
import 'package:omniterm/ui/screens/shell/shell_screen.dart';
import 'package:omniterm/ui/theme/theme.dart';
import 'package:omniterm/ui/view_model/app_state.dart';
import 'package:omniterm/ui/view_model/shell_view_model.dart';
import 'package:provider/provider.dart';

import 'ad_banner_test.dart';
import 'support/fake_secure_storage.dart';
import 'support/fake_shell_transport.dart';

Server testServer({required String name, String status = 'online'}) => Server(
  id: 0,
  name: name,
  host: '10.0.0.1',
  port: 22,
  username: 'root',
  serverColor: 'Default',
  authType: 'password',
  authPassword: 'pw',
  sudoPassword: '',
  notes: '',
  keepAlive: 30,
  sshCompression: false,
  persistentSession: false,
  proxyCommand: '',
  proxyType: 'none',
  proxyHost: '',
  proxyPort: 0,
  proxyUser: '',
  proxyPassword: '',
  agentForwarding: false,
  healthScore: 100,
  lastLatency: 0,
  status: status,
  authStatus: 'ok',
);

void main() {
  late AppDatabase db;
  late AppRepository repo;
  late AppState app;
  late FakeShellTransport transport;
  late ShellViewModel vm;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    repo = AppRepository(db, SecretStore(storage: FakeSecureStorage(<String, String>{})));
    app = AppState(repo);
    transport = FakeShellTransport();
  });

  tearDown(() async {
    vm.dispose();
    app.dispose();
    await transport.dispose();
    await db.close();
  });

  group('Quick Connect Entitlement Gate', () {
    testWidgets('shows entitlement sheet when billing enabled and unlocked is false', (
      tester,
    ) async {
      await repo.insertServer(testServer(name: 'nas'));
      await app.start();
      vm = ShellViewModel(app, transport: transport);

      final licenseController = MockTestLicenseController(
        const LicenseState(enabled: true, loading: false, unlocked: false, productPrice: '\$4.99'),
      );

      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<AppState>.value(value: app),
            ChangeNotifierProvider<ShellViewModel>.value(value: vm),
          ],
          child: MaterialApp(
            theme: omniTheme(OmniThemeMode.dark, Brightness.dark),
            home: Scaffold(body: ShellScreen(licenseController: licenseController)),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('shell.quickConnect')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('shell.quickConnect')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('shell.quickConnectEntitlementSheet')), findsOneWidget);
      expect(find.text('Quick Connect Requires Premium'), findsOneWidget);
      expect(find.byKey(const ValueKey('shell.quickConnectUpgradeButton')), findsOneWidget);

      licenseController.dispose();
      await tester.pump(const Duration(milliseconds: 10));
    });
  });
}
