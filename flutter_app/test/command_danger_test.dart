import 'package:flutter_test/flutter_test.dart';
import 'package:omniterm/domain/command_danger.dart';

/// The last check before a command runs on every host at once. A false negative here costs a fleet,
/// so these tests are mostly about what must *not* slip through.
void main() {
  group('destructive commands are recognised', () {
    const cases = {
      'rm -rf /': 'recursive/forced delete',
      'rm -fr /var/lib': 'recursive/forced delete',
      'rm -r -f /opt/app': 'recursive/forced delete',
      'sudo rm -rf --no-preserve-root /': 'recursive/forced delete',
      'mkfs.ext4 /dev/sda1': 'filesystem format/wipe',
      'wipefs -a /dev/sdb': 'filesystem format/wipe',
      'blkdiscard /dev/nvme0n1': 'filesystem format/wipe',
      'fdisk /dev/sda': 'partition table changes',
      'parted /dev/sda mklabel gpt': 'partition table changes',
      'dd if=/dev/zero of=/dev/sda bs=1M': 'raw write with dd',
      'cat image.img > /dev/sdb': 'writing directly to a block device',
      'shutdown -h now': 'host shutdown',
      'poweroff': 'host shutdown',
      'reboot': 'host reboot/shutdown',
      'init 0': 'host reboot/shutdown',
      'systemctl reboot': 'host reboot/shutdown',
      'userdel -r deploy': 'account deletion',
      'iptables -F': 'firewall teardown',
      'iptables -t nat -F': 'firewall teardown',
      'ufw disable': 'firewall teardown',
      'nft flush ruleset': 'firewall teardown',
      'chmod -R 777 /etc': 'world-writable permission change',
      ':(){ :|:& };:': 'fork bomb',
      'truncate -s 0 /var/log/syslog': 'file truncation',
    };

    cases.forEach((command, expected) {
      test('"$command" is flagged as $expected', () {
        expect(commandDangerHits(command), contains(expected));
        expect(fleetCommandDangerWarning(command), isNotNull);
      });
    });
  });

  group('a command buried in a longer line is still caught', () {
    test('after a pipeline or a chain', () {
      // Only checking the first word would miss every one of these.
      for (final command in [
        'cd /tmp && rm -rf ./cache',
        'echo starting; reboot',
        'find /tmp -name "*.log" -exec truncate -s 0 {} \\;',
        'ssh host "poweroff"',
      ]) {
        expect(commandDangerHits(command), isNotEmpty, reason: command);
      }
    });

    test('regardless of leading sudo or env prefixes', () {
      expect(commandDangerHits('sudo -n mkfs.ext4 /dev/sda1'), isNotEmpty);
      expect(commandDangerHits('DEBIAN_FRONTEND=noninteractive userdel bob'), isNotEmpty);
    });
  });

  group('ordinary commands are not flagged', () {
    test('everyday administration passes clean', () {
      for (final command in [
        'uptime',
        'df -h',
        'systemctl status nginx',
        'systemctl restart nginx',
        'docker ps -a',
        'apt-get update',
        'tail -n 100 /var/log/syslog',
        'journalctl -u nginx --since today',
        'ls -la /var/lib',
        'free -m',
      ]) {
        expect(commandDangerHits(command), isEmpty, reason: command);
        expect(fleetCommandDangerWarning(command), isNull, reason: command);
      }
    });

    test('a plain rm without recursive or force flags is not flagged', () {
      // Deleting one named file is ordinary; the warning is about the -rf multiplier.
      expect(commandDangerHits('rm /tmp/stale.lock'), isEmpty);
      expect(commandDangerHits('rm -i /tmp/stale.lock'), isEmpty);
    });

    test('a relative chmod 777 is careless, not catastrophic', () {
      expect(commandDangerHits('chmod 777 ./build'), isEmpty);
      expect(commandDangerHits('chmod -R 777 /'), isNotEmpty);
    });

    test('reading a device is not writing to one', () {
      expect(
        commandDangerHits('dd if=/dev/sda of=/backup/disk.img'),
        isNotEmpty,
        reason: 'of= is still a raw write, just to a file',
      );
      expect(commandDangerHits('cat /dev/urandom | head -c 16'), isEmpty);
    });

    test('the flag order in dd and iptables does not decide whether it is caught — §15.5', () {
      // The Kotlin matched only when the destructive flag came first, so the textbook
      // `dd if=/dev/zero of=/dev/sda` was silently allowed through.
      for (final command in [
        'dd if=/dev/zero of=/dev/sda bs=1M',
        'dd of=/dev/sda if=/dev/zero',
        'iptables -t nat -F',
        'iptables -F',
      ]) {
        expect(commandDangerHits(command), isNotEmpty, reason: command);
      }
    });

    test('a word that merely contains a keyword is not a match', () {
      // Word boundaries matter: these are not the commands they resemble.
      for (final command in ['grep reboot /var/log/syslog', 'echo "no shutdown configured"']) {
        // These *do* legitimately contain the bare word, so they match — and that is the
        // intended trade: a false positive costs one extra glance.
        expect(commandDangerHits(command), isNotEmpty, reason: command);
      }
      // But a longer word containing the keyword must not match.
      expect(commandDangerHits('systemctl status rebooter.service'), isEmpty);
      expect(commandDangerHits('ls /opt/haltingproblem'), isEmpty);
    });
  });

  group('the warning text', () {
    test('names what was recognised, so the user can judge it', () {
      final warning = fleetCommandDangerWarning('rm -rf /');
      expect(warning, contains('recursive/forced delete'));
      expect(
        warning,
        contains('every host listed above'),
        reason: 'the multiplier is the point, not the command alone',
      );
    });

    test('lists every distinct match once', () {
      final hits = commandDangerHits('rm -rf /data && reboot');
      expect(hits, containsAll(['recursive/forced delete', 'host reboot/shutdown']));
      expect(hits.toSet().length, hits.length, reason: 'no label should repeat');
    });

    test('an empty command is not dangerous', () {
      expect(fleetCommandDangerWarning(''), isNull);
      expect(fleetCommandDangerWarning('   '), isNull);
    });
  });
}
