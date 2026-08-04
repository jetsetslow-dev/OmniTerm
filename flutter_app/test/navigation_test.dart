import 'package:flutter_test/flutter_test.dart';
import 'package:omniterm/ui/navigation.dart';

/// These lock in the exact behaviour of the Kotlin original (`AppViewModel.commitNavigation`,
/// `navigateBack`, `swipeNavigate`). They are assertions about the *ported contract*, not about
/// any particular device, so they stay host-independent.
void main() {
  group('Screen', () {
    test('has the 15 legacy destinations in declaration order', () {
      expect(Screen.values.map((s) => s.wireName).toList(), <String>[
        'Servers',
        'Fleet',
        'Monitor',
        'Shell',
        'SFTP',
        'Infra',
        'Tools',
        'Alerts',
        'QuickScripts',
        'Network',
        'AuthKeys',
        'Backup',
        'HealthScoring',
        'Settings',
        'About',
      ]);
    });

    test('wire names round-trip', () {
      for (final s in Screen.values) {
        expect(Screen.fromWireName(s.wireName), s);
      }
      expect(Screen.fromWireName('NotAScreen'), isNull);
    });
  });

  group('isToolSubScreen', () {
    test('covers Tools and its eight sub-screens', () {
      final subScreens = Screen.values.where(isToolSubScreen).toList();
      expect(subScreens, hasLength(9));
      expect(subScreens, contains(Screen.tools));
      expect(subScreens, contains(Screen.about));
    });

    test('excludes the other six top-level tabs', () {
      for (final s in [
        Screen.servers,
        Screen.fleet,
        Screen.monitor,
        Screen.shell,
        Screen.sftp,
        Screen.infra,
      ]) {
        expect(isToolSubScreen(s), isFalse, reason: '$s is a top-level tab');
      }
    });
  });

  group('NavigationController history', () {
    test('starts on Servers with a single-entry stack', () {
      final nav = NavigationController();
      expect(nav.currentScreen, Screen.servers);
      expect(nav.screenHistory, [Screen.servers]);
    });

    test('pushes new screens onto the stack', () {
      final nav = NavigationController()
        ..navigateTo(Screen.monitor)
        ..navigateTo(Screen.infra);
      expect(nav.screenHistory, [Screen.servers, Screen.monitor, Screen.infra]);
    });

    test('navigating to Servers collapses the stack to the root', () {
      final nav = NavigationController()
        ..navigateTo(Screen.monitor)
        ..navigateTo(Screen.infra)
        ..navigateTo(Screen.servers);
      expect(nav.screenHistory, [Screen.servers]);
      expect(nav.currentScreen, Screen.servers);
    });

    test('revisiting a stacked screen unwinds to it instead of duplicating', () {
      final nav = NavigationController()
        ..navigateTo(Screen.monitor)
        ..navigateTo(Screen.infra)
        ..navigateTo(Screen.monitor);
      expect(nav.screenHistory, [Screen.servers, Screen.monitor]);
    });

    test('A-B-A-B cannot grow the stack without bound', () {
      final nav = NavigationController();
      for (var i = 0; i < 10; i++) {
        nav
          ..navigateTo(Screen.monitor)
          ..navigateTo(Screen.infra);
      }
      expect(nav.screenHistory, [Screen.servers, Screen.monitor, Screen.infra]);
    });

    test('back pops one entry and reports handled', () {
      final nav = NavigationController()
        ..navigateTo(Screen.monitor)
        ..navigateTo(Screen.infra);
      expect(nav.navigateBack(), isTrue);
      expect(nav.currentScreen, Screen.monitor);
    });

    test('back at the root is not handled, so the platform pops the app', () {
      final nav = NavigationController();
      expect(nav.navigateBack(), isFalse);
      expect(nav.currentScreen, Screen.servers);
    });
  });

  group('NavigationController guards', () {
    test('a claiming guard blocks the navigation', () {
      final nav = NavigationController();
      nav.guards.add((from, to) => to == Screen.monitor);
      nav.navigateTo(Screen.monitor);
      expect(nav.currentScreen, Screen.servers);
    });

    test('commitNavigation bypasses guards, as the resolve-and-continue path does', () {
      final nav = NavigationController();
      nav.guards.add((from, to) => true);
      nav.commitNavigation(Screen.monitor);
      expect(nav.currentScreen, Screen.monitor);
    });

    test('a guard sees a null target on back', () {
      final nav = NavigationController()..navigateTo(Screen.monitor);
      Screen? seen = Screen.about;
      nav.guards.add((from, to) {
        seen = to;
        return false;
      });
      nav.navigateBack();
      expect(seen, isNull);
    });
  });

  group('swipeNavigate', () {
    test('pages through subtabs before changing tab', () {
      final nav = NavigationController()..navigateTo(Screen.monitor);
      expect(subtabCount(Screen.monitor), 6);
      for (var i = 1; i < 6; i++) {
        nav.swipeNavigate(forward: true);
        expect(nav.currentScreen, Screen.monitor);
        expect(nav.currentSubtab(Screen.monitor), i);
      }
    });

    test('past the last subtab it advances to the adjacent tab', () {
      final nav = NavigationController()..navigateTo(Screen.monitor);
      for (var i = 0; i < 6; i++) {
        nav.swipeNavigate(forward: true);
      }
      expect(nav.currentScreen, Screen.shell);
    });

    test('a backward swipe only leaves the tab from its first subtab', () {
      final nav = NavigationController()
        ..navigateTo(Screen.infra)
        ..setSubtab(Screen.infra, 4);
      // Infra has 5 subtabs, so swiping back from the last one steps inward, not out.
      nav.swipeNavigate(forward: false);
      expect(nav.currentScreen, Screen.infra);
      expect(nav.currentSubtab(Screen.infra), 3);
    });

    test('always lands on the new tab first subtab, regardless of direction', () {
      final nav = NavigationController()
        // Leave SFTP deep in its subtabs, then come back to it from the right.
        ..navigateTo(Screen.sftp)
        ..setSubtab(Screen.sftp, 3)
        ..navigateTo(Screen.infra)
        ..setSubtab(Screen.infra, 0);
      nav.swipeNavigate(forward: false);
      expect(nav.currentScreen, Screen.sftp);
      expect(
        nav.currentSubtab(Screen.sftp),
        0,
        reason: 'entering a tab resets it to its first subtab',
      );
    });

    test('does nothing at either end of the top-level order', () {
      final nav = NavigationController();
      expect(swipeNavOrder.first, Screen.servers);
      nav.swipeNavigate(forward: false);
      expect(nav.currentScreen, Screen.servers);

      nav.navigateTo(Screen.tools);
      expect(swipeNavOrder.last, Screen.tools);
      nav.swipeNavigate(forward: true);
      expect(nav.currentScreen, Screen.tools);
    });

    test('screens without subtabs swipe straight to the adjacent tab', () {
      expect(subtabCount(Screen.servers), 0);
      final nav = NavigationController();
      nav.swipeNavigate(forward: true);
      expect(nav.currentScreen, Screen.fleet);
    });

    test('setSubtab rejects out-of-range indices', () {
      final nav = NavigationController()
        ..setSubtab(Screen.monitor, 6)
        ..setSubtab(Screen.monitor, -1);
      expect(nav.currentSubtab(Screen.monitor), 0);
    });
  });
}
