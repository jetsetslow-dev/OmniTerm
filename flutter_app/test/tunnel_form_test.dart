import 'package:flutter_test/flutter_test.dart';
import 'package:omniterm/domain/tunnel_form.dart';

void main() {
  group('tunnelSummary', () {
    test('a local forward reads like the ssh flag it is', () {
      expect(
        tunnelSummary(
          kind: 'local',
          bindHost: '127.0.0.1',
          bindPort: 8080,
          destHost: '10.0.0.5',
          destPort: 80,
        ),
        '-L 127.0.0.1:8080 → 10.0.0.5:80',
      );
    });

    test('a remote forward names the direction it actually goes', () {
      expect(
        tunnelSummary(
          kind: 'remote',
          bindHost: '0.0.0.0',
          bindPort: 9000,
          destHost: 'localhost',
          destPort: 3000,
        ),
        '-R 0.0.0.0:9000 → localhost:3000',
      );
    });

    test('a dynamic forward has no destination to name', () {
      // The point of SOCKS is that the destination is decided per connection, so printing one
      // would be inventing a fact.
      expect(
        tunnelSummary(
          kind: 'dynamic',
          bindHost: '127.0.0.1',
          bindPort: 1080,
          destHost: 'ignored',
          destPort: 1234,
        ),
        '-D 127.0.0.1:1080 (SOCKS5)',
      );
    });

    test('the destination is masked but the bind side is not', () {
      // "Hide addresses" is for machines on the user's network. The bind side is on the device in
      // their hand, and masking it would hide the one number they need to point a browser at.
      expect(
        tunnelSummary(
          kind: 'local',
          bindHost: '127.0.0.1',
          bindPort: 8080,
          destHost: 'nas.internal',
          destPort: 443,
          maskHost: (_) => '•••',
        ),
        '-L 127.0.0.1:8080 → •••:443',
      );
    });
  });

  group('tunnelFormError', () {
    String? check({
      String name = 'web',
      String kind = 'local',
      int? serverId = 1,
      String bindHost = '127.0.0.1',
      String bindPort = '8080',
      String destHost = '10.0.0.5',
      String destPort = '80',
    }) => tunnelFormError(
      name: name,
      kind: kind,
      serverId: serverId,
      bindHost: bindHost,
      bindPort: bindPort,
      destHost: destHost,
      destPort: destPort,
    );

    test('a complete local forward is valid', () => expect(check(), isNull));

    test('every required field is named when it is missing', () {
      expect(check(name: '  '), 'Name is required.');
      expect(check(serverId: null), contains('host'));
      expect(check(bindHost: ''), 'Bind address is required.');
      expect(check(destHost: ''), 'Destination host is required.');
    });

    test('ports go through the shared validator, not a local copy of the range', () {
      // The Kotlin's PR #67: a port parsed with a fallback saves a value the user never typed, and
      // a tunnel is the worst place for it — the bind succeeds on an arbitrary port and the forward
      // is running somewhere nobody can find.
      expect(check(bindPort: ''), 'Bind port: Required');
      expect(check(bindPort: 'http'), 'Bind port: Must be a whole number');
      expect(check(bindPort: '0'), 'Bind port: Must be 1-65535');
      expect(check(bindPort: '65536'), 'Bind port: Must be 1-65535');
      expect(check(destPort: ''), 'Destination port: Required');
    });

    test('a dynamic forward is not asked for a destination it cannot have', () {
      expect(check(kind: 'dynamic', destHost: '', destPort: ''), isNull);
    });

    test('an unknown mode is refused rather than treated as local', () {
      // Silently defaulting would forward traffic somewhere the user did not ask for.
      expect(check(kind: 'sideways'), 'Choose a forwarding mode.');
    });
  });

  group('tunnelHasDestination', () {
    test('only a dynamic forward lacks one', () {
      expect(tunnelHasDestination('local'), isTrue);
      expect(tunnelHasDestination('remote'), isTrue);
      expect(tunnelHasDestination('dynamic'), isFalse);
    });
  });
}
