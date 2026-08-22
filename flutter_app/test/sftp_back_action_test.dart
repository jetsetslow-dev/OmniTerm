import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omniterm/domain/sftp_back_action.dart';
import 'package:omniterm/ui/navigation.dart';
import 'package:omniterm/ui/widgets/back_interceptor.dart';
import 'package:provider/provider.dart';

/// The defect these cover: the port shipped a single root-level `PopScope` and none of Kotlin's
/// five screen-level `BackHandler`s, so Back from three directories deep in the file browser left
/// the screen entirely instead of walking up one folder — and Back with an image preview open
/// navigated away while leaving the preview loaded underneath.
void main() {
  /// Everything off: a host browser sitting at its resolved root with nothing selected.
  SftpBackAction actionWith({
    bool previewOpen = false,
    bool onFilesTab = true,
    bool hasSelection = false,
    bool searchResultsShown = false,
    String path = '/',
    bool shareOpen = false,
  }) => sftpBackAction(
    previewOpen: previewOpen,
    onFilesTab: onFilesTab,
    hasSelection: hasSelection,
    searchResultsShown: searchResultsShown,
    path: path,
    shareOpen: shareOpen,
  );

  group('sftpBackAction', () {
    test('a host at its root does not claim the press', () {
      expect(actionWith(), SftpBackAction.none);
    });

    test('an unresolved home directory has no parent to walk to', () {
      // `openPath('')` is the pre-listing state; treating it as a directory would send `goUp` to
      // `parentPath('')`.
      expect(actionWith(path: ''), SftpBackAction.none);
    });

    test('a directory below the root walks up', () {
      expect(actionWith(path: '/etc/nginx'), SftpBackAction.goUp);
    });

    test('a share at its root closes the browser instead of leaving the screen', () {
      // The asymmetry with a host is deliberate: the share list is somewhere to go back *to*.
      expect(actionWith(shareOpen: true, path: ''), SftpBackAction.closeShare);
      expect(actionWith(shareOpen: true, path: '/'), SftpBackAction.closeShare);
    });

    test('a share below its root walks up before it closes', () {
      expect(actionWith(shareOpen: true, path: '/media/film'), SftpBackAction.goUp);
    });

    test('the other tabs leave Back to app navigation', () {
      for (final path in ['', '/', '/etc/nginx']) {
        expect(
          actionWith(onFilesTab: false, path: path),
          SftpBackAction.none,
          reason: 'path $path off the Files tab',
        );
      }
    });
  });

  group('sftpBackAction unwinds one layer at a time', () {
    test('selection outranks search, depth and the share', () {
      expect(
        actionWith(
          hasSelection: true,
          searchResultsShown: true,
          path: '/etc/nginx',
          shareOpen: true,
        ),
        SftpBackAction.clearSelection,
      );
    });

    test('search outranks depth', () {
      expect(actionWith(searchResultsShown: true, path: '/etc/nginx'), SftpBackAction.clearSearch);
    });

    test('the preview outranks everything, including the tab it is not part of', () {
      // Kotlin draws the preview above the whole app and disables the app-level handler while it
      // is up, so it must win even when the Files tab is not the one showing.
      expect(
        actionWith(
          previewOpen: true,
          onFilesTab: false,
          hasSelection: true,
          searchResultsShown: true,
          path: '/etc/nginx',
          shareOpen: true,
        ),
        SftpBackAction.closePreview,
      );
    });

    test('every layer is reachable by peeling the one above it', () {
      // A negative control on the ordering itself: if any branch shadowed another, one of these
      // would repeat its predecessor rather than advancing.
      expect(
        actionWith(
          previewOpen: true,
          hasSelection: true,
          searchResultsShown: true,
          path: '/media/film',
          shareOpen: true,
        ),
        SftpBackAction.closePreview,
      );
      expect(
        actionWith(
          hasSelection: true,
          searchResultsShown: true,
          path: '/media/film',
          shareOpen: true,
        ),
        SftpBackAction.clearSelection,
      );
      expect(
        actionWith(searchResultsShown: true, path: '/media/film', shareOpen: true),
        SftpBackAction.clearSearch,
      );
      expect(actionWith(path: '/media/film', shareOpen: true), SftpBackAction.goUp);
      expect(actionWith(path: '/', shareOpen: true), SftpBackAction.closeShare);
      expect(actionWith(path: '/'), SftpBackAction.none);
    });
  });

  group('BackInterceptor', () {
    /// Pumps [child] under a [NavigationController] and hands back the controller to press Back on.
    Future<NavigationController> pumpUnder(WidgetTester tester, Widget child) async {
      final nav = NavigationController();
      await tester.pumpWidget(
        ChangeNotifierProvider<NavigationController>.value(
          value: nav,
          child: MaterialApp(home: child),
        ),
      );
      return nav;
    }

    testWidgets('a claimed press stops app navigation', (tester) async {
      var pressed = 0;
      final nav = await pumpUnder(
        tester,
        BackInterceptor(
          onBack: () {
            pressed++;
            return true;
          },
          child: const SizedBox(),
        ),
      );
      nav.navigateTo(Screen.sftp);
      expect(nav.currentScreen, Screen.sftp);

      expect(nav.navigateBack(), isTrue);
      expect(pressed, 1);
      // The point of the guard: the screen kept its place while it unwound its own state.
      expect(nav.currentScreen, Screen.sftp);
    });

    testWidgets('an unclaimed press falls through to app navigation', (tester) async {
      final nav = await pumpUnder(
        tester,
        BackInterceptor(onBack: () => false, child: const SizedBox()),
      );
      nav.navigateTo(Screen.sftp);

      expect(nav.navigateBack(), isTrue);
      expect(nav.currentScreen, Screen.servers);
    });

    testWidgets('forward navigation is never intercepted', (tester) async {
      var pressed = 0;
      final nav = await pumpUnder(
        tester,
        BackInterceptor(
          onBack: () {
            pressed++;
            return true;
          },
          child: const SizedBox(),
        ),
      );

      nav.navigateTo(Screen.monitor);
      expect(nav.currentScreen, Screen.monitor);
      expect(pressed, 0, reason: 'a tab tap must not unwind screen state');
    });

    testWidgets('an unmounted interceptor stops swallowing Back', (tester) async {
      // Without deregistration the guard outlives its screen, and Back stays broken app-wide for
      // the rest of the session.
      var pressed = 0;
      final nav = NavigationController();
      Widget host({required bool showInterceptor}) =>
          ChangeNotifierProvider<NavigationController>.value(
            value: nav,
            child: MaterialApp(
              home: showInterceptor
                  ? BackInterceptor(
                      onBack: () {
                        pressed++;
                        return true;
                      },
                      child: const SizedBox(),
                    )
                  : const SizedBox(),
            ),
          );

      await tester.pumpWidget(host(showInterceptor: true));
      nav.navigateTo(Screen.sftp);
      expect(nav.navigateBack(), isTrue);
      expect(pressed, 1);

      await tester.pumpWidget(host(showInterceptor: false));
      nav.navigateTo(Screen.sftp);
      expect(nav.navigateBack(), isTrue);
      expect(pressed, 1, reason: 'the disposed guard must not run');
      expect(nav.currentScreen, Screen.servers);
    });
  });
}
