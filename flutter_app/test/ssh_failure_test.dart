import 'package:flutter_test/flutter_test.dart';
import 'package:omniterm/domain/ssh_failure.dart';

void main() {
  group('what a transport error means', () {
    test('the failures a user can act on are named', () {
      // Ported from `classifySshConnectionFailure` (`ui/AppViewModel.kt:388`). The raw detail is
      // accurate and useless: "SSHAuthFailError" does not tell anyone to check their key.
      expect(classifySshFailure('SSH Error: SSHAuthFailError'), SshFailureKind.authentication);
      expect(
        classifySshFailure('SSH Error: SocketException: Connection refused (errno = 111)'),
        SshFailureKind.refused,
      );
      expect(classifySshFailure('SSH Error: command timed out'), SshFailureKind.timeout);
      expect(
        classifySshFailure('SSH Error: Failed host lookup: nas.local'),
        SshFailureKind.hostNotFound,
      );
      expect(
        classifySshFailure('SSH Error: Network is unreachable'),
        SshFailureKind.networkUnreachable,
      );
      expect(classifySshFailure('SSH Error: Connection reset by peer'), SshFailureKind.dropped);
      expect(classifySshFailure('SSH Error: HostKey has been changed'), SshFailureKind.hostKey);
    });

    test('the prefix is optional, and matching ignores case', () {
      expect(classifySshFailure('connection refused'), SshFailureKind.refused);
      expect(classifySshFailure('SSH Error: AUTH FAIL'), SshFailureKind.authentication);
    });

    test('an unrecognised failure keeps its own detail', () {
      // Flattening every unknown into one sentence throws away the only thing that distinguishes
      // them when someone reports a problem.
      expect(
        describeSshFailure('SSH Error: something nobody has seen'),
        'something nobody has seen',
      );
      expect(classifySshFailure('SSH Error: something nobody has seen'), SshFailureKind.unknown);
    });

    test('an empty failure still says something', () {
      expect(describeSshFailure('SSH Error:'), SshFailureKind.unknown.message);
      expect(describeSshFailure(''), SshFailureKind.unknown.message);
    });

    test('a known failure is described by its message, not the raw text', () {
      expect(
        describeSshFailure('SSH Error: SSHAuthFailError'),
        'Authentication failed (bad key or password)',
      );
    });
  });
}
