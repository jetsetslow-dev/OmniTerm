import 'package:flutter_test/flutter_test.dart';
import 'package:omniterm/domain/whois.dart';

void main() {
  group('where a query starts', () {
    test('an address goes to a regional registry', () {
      expect(initialWhoisServer('8.8.8.8'), 'whois.arin.net');
      expect(initialWhoisServer('2001:4860:4860::8888'), 'whois.arin.net');
    });

    test('a name goes to IANA, which knows who owns the TLD', () {
      expect(initialWhoisServer('example.com'), 'whois.iana.org');
      expect(initialWhoisServer('bbc.co.uk'), 'whois.iana.org');
    });
  });

  group('looksLikeIpAddress', () {
    test('the ordinary forms', () {
      expect(looksLikeIpAddress('192.168.1.1'), isTrue);
      expect(looksLikeIpAddress('0.0.0.0'), isTrue);
      expect(looksLikeIpAddress('255.255.255.255'), isTrue);
      expect(looksLikeIpAddress('2001:db8::1'), isTrue);
      expect(looksLikeIpAddress('fe80::1%eth0'), isTrue);
    });

    test('names are not addresses', () {
      expect(looksLikeIpAddress('example.com'), isFalse);
      expect(looksLikeIpAddress('1.2.3.example.com'), isFalse);
      expect(looksLikeIpAddress(''), isFalse);
    });

    test('an octet out of range is not an address', () {
      // 999 is a name-shaped thing as far as this is concerned; guessing wrong costs one hop.
      expect(looksLikeIpAddress('999.1.1.1'), isFalse);
      expect(looksLikeIpAddress('1.2.3'), isFalse);
      expect(looksLikeIpAddress('1.2.3.4.5'), isFalse);
    });
  });

  group('cleanWhoisServerHost', () {
    test('the spellings registries actually use', () {
      // Every one of these appeared in a real referral field.
      expect(cleanWhoisServerHost('whois.nic.uk'), 'whois.nic.uk');
      expect(cleanWhoisServerHost('whois://whois.nic.uk'), 'whois.nic.uk');
      expect(cleanWhoisServerHost('whois.verisign-grs.com:43'), 'whois.verisign-grs.com');
      expect(cleanWhoisServerHost('rwhois://rwhois.example.net:4321/'), 'rwhois.example.net');
      expect(cleanWhoisServerHost('  whois.iana.org  '), 'whois.iana.org');
      expect(cleanWhoisServerHost('https://whois.example.com/lookup'), 'whois.example.com');
    });
  });

  group('isUsableWhoisHost', () {
    // This is a security boundary, not tidying: the value comes from a remote reply and decides
    // what the app connects to next.
    test('a plain hostname is fine', () {
      expect(isUsableWhoisHost('whois.nic.uk'), isTrue);
      expect(isUsableWhoisHost('whois-1.example-registry.com'), isTrue);
    });

    test('anything that is not a hostname is refused', () {
      for (final value in [
        '',
        'localhost',
        'whois nic uk',
        'whois.nic.uk extra',
        'whois.nic.uk/../etc',
        r'$(id).example.com',
        'whois.nic.uk;ls',
        '.example.com',
        'example.com.',
        'exam..ple.com',
        '-example.com',
        'example.com-',
      ]) {
        expect(isUsableWhoisHost(value), isFalse, reason: value);
      }
    });
  });

  group('extractReferralServer', () {
    test('IANA points at the registry', () {
      // Trimmed from a real whois.iana.org reply for `.com`.
      const response =
          'domain:       COM\n'
          'organisation: VeriSign Global Registry Services\n'
          'refer:        whois.verisign-grs.com\n'
          'status:       ACTIVE\n';

      expect(extractReferralServer(response), 'whois.verisign-grs.com');
    });

    test('a registry points at the registrar', () {
      const response =
          'Domain Name: EXAMPLE.COM\n'
          '   Registrar WHOIS Server: whois.registrar.example\n'
          '   Registrar URL: http://registrar.example\n';

      expect(extractReferralServer(response), 'whois.registrar.example');
    });

    test('ARIN spells it differently again', () {
      expect(
        extractReferralServer(
          'NetRange: 1.0.0.0\nReferralServer: rwhois://rwhois.example.net:4321',
        ),
        'rwhois.example.net',
      );
    });

    test('a record with no referral holds the answer itself', () {
      expect(extractReferralServer('Domain Name: EXAMPLE.COM\nRegistrant: Someone\n'), isNull);
      expect(extractReferralServer(''), isNull);
    });

    test('a referral that is not a hostname is ignored', () {
      // Rather than connecting somewhere unexpected, the first response stands. The reply is free
      // text from a server the user named; nothing about it is trustworthy by default.
      for (final value in [
        'refer: not a host',
        r'refer: $(curl evil.example)',
        'refer: whois.nic.uk extra words',
        'refer:',
      ]) {
        expect(extractReferralServer(value), isNull, reason: value);
      }
    });

    test('a port or a path is stripped rather than rejected', () {
      // That is what the field means when a registry writes it — unlike a space, which means the
      // field is malformed and picking a half would be this app guessing.
      expect(extractReferralServer('refer: whois.nic.uk:43/lookup'), 'whois.nic.uk');
    });

    test('the key must start the line, not appear in prose', () {
      // "Please refer: to the registrar" in a comment block is not a referral.
      const response = 'Domain: EXAMPLE\nNotes: please refer: whois.evil.example for details\n';
      expect(extractReferralServer(response), isNull);
    });

    test('the first usable referral wins', () {
      const response = 'refer: whois.first.example\nRegistrar WHOIS Server: whois.second.example\n';
      expect(extractReferralServer(response), 'whois.first.example');
    });
  });

  test('the request is CRLF-terminated, as the protocol says', () {
    // Servers that tolerate a bare newline are the exception; several hang waiting for the CR.
    expect(whoisRequestLine('example.com'), 'example.com\r\n');
    expect(whoisRequestLine('  example.com  '), 'example.com\r\n');
  });
}
