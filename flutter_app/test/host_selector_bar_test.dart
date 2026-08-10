import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omniterm/data/app_database.dart';
import 'package:omniterm/domain/host_display.dart';
import 'package:omniterm/ui/theme/theme.dart';
import 'package:omniterm/ui/widgets/host_selector_bar.dart';

/// The shared host picker, ported from `ServerSelectorBar` (`ui/AppUi.kt:83`).
///
/// Flutter had grown one `DropdownButton` per screen and they had drifted apart, but the substance
/// is what they all left out: Kotlin's bar carries `user@host · latency` beside the name, so hosts
/// with similar nicknames can be told apart and a quiet one is visible without leaving the screen.
void main() {
  Server host({
    required int id,
    required String name,
    String username = 'root',
    String address = '10.0.0.1',
    String status = 'online',
    int latency = 12,
  }) => Server(
    id: id,
    name: name,
    host: address,
    port: 22,
    username: username,
    serverColor: 'Default',
    authType: 'password',
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
    lastLatency: latency,
    status: status,
    authStatus: 'ok',
  );

  Future<void> pump(
    WidgetTester tester, {
    required List<Server> hosts,
    required Server selected,
    String labelPrefix = '',
    ValueChanged<int?>? onChanged,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: omniTheme(OmniThemeMode.dark, Brightness.dark),
        home: Scaffold(
          body: HostSelectorBar(
            keyPrefix: 'test.picker',
            hosts: hosts,
            selected: selected,
            labelPrefix: labelPrefix,
            onChanged: onChanged ?? (_) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('the closed bar names the machine, not just the nickname', (tester) async {
    final only = host(id: 1, name: 'web-1', username: 'deploy', address: '10.0.0.7');
    await pump(tester, hosts: [only], selected: only);

    final detail = tester.widget<Text>(
      find.byKey(const ValueKey('test.picker.detail.1')),
    );
    expect(detail.data, contains('deploy@10.0.0.7'));
  });

  testWidgets('the closed bar shows latency for an online host', (tester) async {
    final only = host(id: 1, name: 'web-1', latency: 42);
    await pump(tester, hosts: [only], selected: only);

    expect(
      tester.widget<Text>(find.byKey(const ValueKey('test.picker.detail.1'))).data,
      contains('42ms'),
    );
  });

  testWidgets('an offline host says so instead of showing a stale number', (tester) async {
    // A latency from before the host went quiet reads as if it were still answering.
    final only = host(id: 1, name: 'web-1', status: 'offline', latency: 42);
    await pump(tester, hosts: [only], selected: only);

    final detail = tester.widget<Text>(
      find.byKey(const ValueKey('test.picker.detail.1')),
    );
    expect(detail.data, contains('offline'));
    expect(detail.data, isNot(contains('42ms')));
  });

  testWidgets('a label prefix is applied without losing the detail line', (tester) async {
    final only = host(id: 1, name: 'web-1');
    await pump(tester, hosts: [only], selected: only, labelPrefix: 'Containers · ');

    expect(find.text('Containers · web-1'), findsOneWidget);
    expect(find.byKey(const ValueKey('test.picker.detail.1')), findsOneWidget);
  });

  testWidgets('the open list distinguishes hosts by user@host', (tester) async {
    // The case this exists for: two hosts whose names differ by a suffix.
    final a = host(id: 1, name: 'web-2', address: '10.0.0.2');
    final b = host(id: 2, name: 'web-2-old', address: '10.0.0.9');
    await pump(tester, hosts: [a, b], selected: a);

    await tester.tap(find.byKey(const ValueKey('test.picker')));
    await tester.pumpAndSettle();

    expect(find.text('web-2 — root@10.0.0.2'), findsWidgets);
    expect(find.text('web-2-old — root@10.0.0.9'), findsWidgets);
  });

  testWidgets('choosing another host reports it', (tester) async {
    final a = host(id: 1, name: 'a');
    final b = host(id: 2, name: 'b');
    int? chosen;
    await pump(tester, hosts: [a, b], selected: a, onChanged: (id) => chosen = id);

    await tester.tap(find.byKey(const ValueKey('test.picker')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('b — root@10.0.0.1').last);
    await tester.pumpAndSettle();

    expect(chosen, 2);
  });

  testWidgets('the address obeys Hide addresses', (tester) async {
    // The picker is exactly the sort of chrome that ends up in a screenshot.
    HostDisplay.instance.hideSensitiveInfo = true;
    addTearDown(() => HostDisplay.instance.hideSensitiveInfo = false);
    final only = host(id: 1, name: 'web-1', address: '10.0.0.7');
    await pump(tester, hosts: [only], selected: only);

    expect(
      tester.widget<Text>(find.byKey(const ValueKey('test.picker.detail.1'))).data,
      isNot(contains('10.0.0.7')),
    );
  });
}
