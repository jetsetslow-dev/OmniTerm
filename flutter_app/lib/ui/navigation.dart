import 'package:flutter/foundation.dart';

/// The app's 15 destinations, ported verbatim from `Screen` in `ui/AppViewModel.kt`.
///
/// Order is significant: it is the declaration order the legacy enum used, and several call sites
/// (persistence of the last screen, widget/shortcut deep links) round-trip the *name*, so neither
/// the names nor the set may change.
enum Screen {
  servers,
  fleet,
  monitor,
  shell,
  sftp,
  infra,
  tools,
  alerts,
  quickScripts,
  network,
  authKeys,
  backup,
  healthScoring,
  settings,
  about;

  /// The legacy Kotlin enum-constant name, used wherever a screen is persisted or sent across a
  /// platform boundary (saved state, launcher shortcuts, home-screen widget intents).
  String get wireName => switch (this) {
    Screen.servers => 'Servers',
    Screen.fleet => 'Fleet',
    Screen.monitor => 'Monitor',
    Screen.shell => 'Shell',
    Screen.sftp => 'SFTP',
    Screen.infra => 'Infra',
    Screen.tools => 'Tools',
    Screen.alerts => 'Alerts',
    Screen.quickScripts => 'QuickScripts',
    Screen.network => 'Network',
    Screen.authKeys => 'AuthKeys',
    Screen.backup => 'Backup',
    Screen.healthScoring => 'HealthScoring',
    Screen.settings => 'Settings',
    Screen.about => 'About',
  };

  static Screen? fromWireName(String name) {
    for (final s in Screen.values) {
      if (s.wireName == name) return s;
    }
    return null;
  }
}

/// The nine screens that live under the Tools tab. While any of them is active the Tools bottom-nav
/// item stays highlighted. Ported from `isToolSubScreen()` in `ui/AppUi.kt`.
bool isToolSubScreen(Screen screen) => const {
  Screen.tools,
  Screen.alerts,
  Screen.quickScripts,
  Screen.network,
  Screen.authKeys,
  Screen.backup,
  Screen.healthScoring,
  Screen.settings,
  Screen.about,
}.contains(screen);

/// Top-level tabs in horizontal-swipe order (`swipeNavOrder` in `ui/AppViewModel.kt`).
const swipeNavOrder = <Screen>[
  Screen.servers,
  Screen.fleet,
  Screen.monitor,
  Screen.shell,
  Screen.sftp,
  Screen.infra,
  Screen.tools,
];

/// Number of inner subtabs for a screen that supports horizontal subtab paging (0 = none).
int subtabCount(Screen screen) => switch (screen) {
  Screen.monitor => 6,
  Screen.infra => 5,
  Screen.fleet => 3,
  Screen.sftp => 4,
  Screen.network => 9,
  Screen.alerts => 3,
  Screen.quickScripts => 2,
  _ => 0,
};

/// A guard that can intercept a navigation before it commits, returning true when it has taken
/// over (by showing a dialog, say) and navigation must not proceed.
///
/// This is how the legacy `navigateTo` behaviour is preserved without dragging the whole
/// 12k-line ViewModel into the navigator: the unsaved-Settings guard and the leave-terminal
/// transaction register themselves here, keeping their exact precedence.
typedef NavigationGuard = bool Function(Screen from, Screen? to);

/// Owns the current screen, the back stack, and subtab paging.
///
/// Ported from the navigation half of `AppViewModel`: `currentScreen`, `screenHistory`,
/// `navigateTo`/`commitNavigation`, `navigateBack` and `swipeNavigate`. Behaviour is intentionally
/// identical, including the quirks noted inline.
class NavigationController extends ChangeNotifier {
  Screen _current = Screen.servers;
  final List<Screen> _history = <Screen>[Screen.servers];
  final Map<Screen, int> _subtabs = <Screen, int>{};

  /// Guards run in insertion order; the first to claim the navigation wins.
  final List<NavigationGuard> guards = <NavigationGuard>[];

  Screen get currentScreen => _current;
  List<Screen> get screenHistory => List.unmodifiable(_history);

  int currentSubtab(Screen screen) => _subtabs[screen] ?? 0;

  void setSubtab(Screen screen, int index) {
    if (index < 0 || index >= subtabCount(screen)) return;
    if (_subtabs[screen] == index) return;
    _subtabs[screen] = index;
    notifyListeners();
  }

  void navigateTo(Screen screen) {
    // Compose's mutableStateOf does not recompose when the same enum value is assigned. Mirror
    // that here: rebuilding the active route from a bottom-nav re-tap can briefly give lazily laid
    // out grids a zero viewport on a real device, even though no navigation occurred.
    if (screen == _current) return;
    for (final guard in guards) {
      if (guard(_current, screen)) return;
    }
    commitNavigation(screen);
  }

  /// Applies the navigation unconditionally, bypassing the guards. Called by a guard once the user
  /// has resolved whatever it intercepted for (discarded Settings edits, chose how to leave the
  /// terminal).
  void commitNavigation(Screen screen) {
    if (screen == Screen.servers) {
      // Servers is the app's root: reaching it always collapses the stack rather than deepening it.
      _history
        ..clear()
        ..add(Screen.servers);
    } else if (_history.contains(screen)) {
      // Revisiting a screen already on the stack unwinds back to it instead of pushing a duplicate,
      // so A→B→A→B cannot grow without bound.
      final index = _history.indexOf(screen);
      _history.removeRange(index + 1, _history.length);
    } else {
      _history.add(screen);
    }
    _current = screen;
    notifyListeners();
  }

  /// Returns true when the back press was handled (so the platform must not pop the app).
  bool navigateBack() {
    for (final guard in guards) {
      if (guard(_current, null)) return true;
    }
    if (_history.length > 1) {
      _history.removeLast();
      _current = _history.last;
      notifyListeners();
      return true;
    }
    return false;
  }

  /// Horizontal swipe: page through the current screen's subtabs, and at either edge move to the
  /// adjacent top-level tab.
  void swipeNavigate({required bool forward}) {
    final screen = _current;
    final subCount = subtabCount(screen);
    if (subCount > 1) {
      final next = currentSubtab(screen) + (forward ? 1 : -1);
      if (next >= 0 && next < subCount) {
        setSubtab(screen, next);
        return;
      }
    }
    // At a subtab edge (or no subtabs): move to the adjacent top-level tab.
    final idx = swipeNavOrder.indexOf(screen);
    if (idx == -1) return;
    final nextIdx = idx + (forward ? 1 : -1);
    if (nextIdx < 0 || nextIdx >= swipeNavOrder.length) return;
    final target = swipeNavOrder[nextIdx];
    // Always land on the new tab's first subtab, regardless of swipe direction.
    if (subtabCount(target) > 1) _subtabs[target] = 0;
    navigateTo(target);
  }
}
