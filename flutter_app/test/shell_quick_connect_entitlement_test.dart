import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omniterm/data/app_database.dart';
import 'package:omniterm/data/app_repository.dart';
import 'package:omniterm/l10n/app_localizations.dart';
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

  Future<MockTestLicenseController> pump(
    WidgetTester tester, {
    required bool unlocked,
    bool withHost = true,
  }) async {
    if (withHost) await repo.insertServer(testServer(name: 'nas'));
    await app.start();
    vm = ShellViewModel(app, transport: transport);
    final licenseController = MockTestLicenseController(
      LicenseState(enabled: true, loading: false, unlocked: unlocked, productPrice: '\$4.99'),
    );
    addTearDown(licenseController.dispose);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<AppState>.value(value: app),
          ChangeNotifierProvider<ShellViewModel>.value(value: vm),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          theme: omniTheme(OmniThemeMode.dark, Brightness.dark),
          home: Scaffold(body: ShellScreen(licenseController: licenseController)),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return licenseController;
  }

  // Kotlin's rule (`isQuickConnectAvailable`): on the free Play Store build every Quick connect
  // entry is absent rather than shown and refused, because there every host goes through the saved
  // list. Flutter used to show the button and answer it with an upgrade sheet.
  group('Quick connect on the free Play Store build', () {
    testWidgets('the connect prompt offers no Quick connect while locked', (tester) async {
      await pump(tester, unlocked: false);

      expect(find.byKey(const ValueKey('shell.connect.card')), findsOneWidget);
      expect(find.byKey(const ValueKey('shell.quickConnect')), findsNothing);
      expect(find.text('Quick Connect Requires Premium'), findsNothing);
      await tester.pump(const Duration(milliseconds: 10));
    });

    testWidgets('the no-hosts screen offers no Quick connect while locked', (tester) async {
      await pump(tester, unlocked: false, withHost: false);

      expect(find.text('Add a server first.'), findsOneWidget);
      expect(find.byKey(const ValueKey('shell.empty.quickConnect')), findsNothing);
      await tester.pump(const Duration(milliseconds: 10));
    });

    testWidgets('unlocking brings the entries back without a restart', (tester) async {
      final license = await pump(tester, unlocked: false, withHost: false);

      (license.state as ValueNotifier<LicenseState>).value = const LicenseState(
        enabled: true,
        loading: false,
        unlocked: true,
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('shell.empty.quickConnect')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('shell.empty.quickConnect')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('shell.quick.dialog')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('shell.quick.close')));
      await tester.pumpAndSettle();
    });

    testWidgets('an unlocked build offers it on the connect prompt', (tester) async {
      await pump(tester, unlocked: true);

      expect(find.byKey(const ValueKey('shell.quickConnect')), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 10));
    });
  });
}
