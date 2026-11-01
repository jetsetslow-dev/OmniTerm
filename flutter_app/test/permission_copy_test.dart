import 'package:flutter_test/flutter_test.dart';
import 'package:omniterm/domain/permission_copy.dart';

/// The runtime-permission copy, ported from `local_network_access_explanation`
/// (`res/values/strings.xml:33`).
///
/// The dialogs themselves are unreachable from the host suite — the permission probes fall back to
/// "not required" without a platform channel, so nothing renders. These assert the *properties* a
/// consent prompt has to have, not a transcript, which would break on every wording change without
/// telling anyone anything.
void main() {
  group('the local-network explanation', () {
    test('says why the permission is wanted', () {
      expect(localNetworkPermissionExplanation, contains('SSH'));
      expect(localNetworkPermissionExplanation, contains('Wake-on-LAN'));
    });

    test('says what declining costs, not only what accepting buys', () {
      // The sentence the Flutter port dropped. Without it "Not now" looks free, on a prompt the
      // user cannot easily get back to once dismissed.
      expect(localNetworkPermissionExplanation, contains('Not now'));
      expect(
        localNetworkPermissionExplanation,
        contains('may not work'),
        reason: 'the consequence of declining has to be stated',
      );
    });

    test('does not overstate the cost', () {
      // Internet hosts keep working. A prompt that implied the app stops functioning would be
      // pressuring the user into a permission they may not want to give.
      expect(localNetworkPermissionExplanation, contains('internet hosts remain available'));
    });
  });
}
