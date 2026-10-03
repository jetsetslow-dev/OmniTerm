import 'package:flutter_test/flutter_test.dart';
import 'package:omniterm/data/network/network_probe.dart';
import 'package:omniterm/domain/share_scan.dart';

/// Finding shares on the LAN, ported from `scanNetworkShares` (`ui/AppViewModel.kt:7372`).
///
/// Flutter's Shares tab could only add a share by typing its address, so a NAS had to already be
/// known before it could be saved — the discovery half of the feature was missing entirely.
void main() {
  group('ports for the selected protocols', () {
    test('each protocol brings its own port', () {
      expect(portsForProtocols(['SMB']), [445]);
      expect(portsForProtocols(['NFS']), [2049]);
    });

    test('WebDAV is probed on both plain and TLS', () {
      // A NAS commonly answers on only one of them, so probing one would miss half of them.
      expect(portsForProtocols(['WEBDAV']), [80, 443]);
    });

    test('a port shared by two protocols is probed once', () {
      final ports = portsForProtocols(['SMB', 'SFTP', 'SMB']);
      expect(ports, [445, 22]);
    });

    test('the order is the table\'s, not the caller\'s', () {
      // So a sweep is reproducible rather than depending on set iteration order.
      expect(portsForProtocols(['NFS', 'SMB']), [445, 2049]);
    });

    test('nothing selected probes nothing', () {
      expect(portsForProtocols(const []), isEmpty);
    });
  });

  group('the stored protocol selection', () {
    test('round-trips', () {
      expect(decodeScanProtocols(encodeScanProtocols(['SMB', 'NFS'])), ['SMB', 'NFS']);
    });

    test('never stored means everything', () {
      expect(decodeScanProtocols(null), allScanProtocols);
    });

    test('a value naming nothing known falls back rather than scanning nothing', () {
      // An empty selection probes no ports and reports "nothing found", which is indistinguishable
      // from a quiet network and is the wrong answer.
      expect(decodeScanProtocols(''), allScanProtocols);
      expect(decodeScanProtocols('GOPHER,IPX'), allScanProtocols);
    });

    test('unknown entries are dropped but known ones survive', () {
      expect(decodeScanProtocols('SMB,GOPHER'), ['SMB']);
    });

    test('case and spacing from an older write are tolerated', () {
      expect(decodeScanProtocols(' smb , nfs '), ['SMB', 'NFS']);
    });
  });

  group('reading a subnet the user typed', () {
    test('the forms people actually type', () {
      expect(scanPrefixOf('192.168.1.0/24'), '192.168.1');
      expect(scanPrefixOf('192.168.1.0'), '192.168.1');
      expect(scanPrefixOf('192.168.1'), '192.168.1');
      expect(scanPrefixOf('  10.0.0.0/24  '), '10.0.0');
    });

    test('anything that is not a subnet is refused rather than guessed at', () {
      // Refusing is what lets the screen say "enter a subnet like…" instead of sweeping 0.0.0/24.
      expect(scanPrefixOf(''), isNull);
      expect(scanPrefixOf('192.168'), isNull);
      expect(scanPrefixOf('nas.local'), isNull);
      expect(scanPrefixOf('999.1.1.0/24'), isNull);
      expect(scanPrefixOf('192.-1.1.0'), isNull);
    });
  });

  group('turning a sweep into share hits', () {
    ScannedHost host(String address, List<int> ports) =>
        ScannedHost(address: address, latency: null, openPorts: ports);

    test('an open port is read as the protocol that lives there', () {
      final hits = hitsFromScan([
        host('10.0.0.5', [445]),
      ], allScanProtocols);

      expect(hits.single.protocol, 'SMB');
      expect(hits.single.address, '10.0.0.5');
      expect(hits.single.port, 445);
    });

    test('one host offering several protocols is several hits', () {
      final hits = hitsFromScan([
        host('10.0.0.5', [445, 22]),
      ], allScanProtocols);
      expect(hits.map((h) => h.protocol), ['SMB', 'SFTP']);
    });

    test('a port nobody asked about is ignored', () {
      // The sweep may report ports from a wider list; only the selected protocols become hits.
      final hits = hitsFromScan(
        [
          host('10.0.0.5', [445, 22]),
        ],
        ['SMB'],
      );
      expect(hits.map((h) => h.protocol), ['SMB']);
    });

    test('a host with nothing open contributes nothing', () {
      expect(hitsFromScan([host('10.0.0.5', const [])], allScanProtocols), isEmpty);
    });

    test('the same service twice is one row', () {
      final hits = hitsFromScan([
        host('10.0.0.5', [445]),
        host('10.0.0.5', [445]),
      ], allScanProtocols);
      expect(hits, hasLength(1));
    });

    test('WebDAV on both ports is two rows, because they are different endpoints', () {
      // One is plain HTTP and the other TLS; saving the wrong one gives a share that will not open.
      final hits = hitsFromScan(
        [
          host('10.0.0.5', [80, 443]),
        ],
        ['WEBDAV'],
      );
      expect(hits.map((h) => h.port), [80, 443]);
    });

    test('the label names the endpoint, not just the host', () {
      final hit = hitsFromScan(
        [
          host('10.0.0.5', [2049]),
        ],
        ['NFS'],
      ).single;
      expect(hit.label, 'NFS on 10.0.0.5:2049');
    });
  });
}
