/// WHOIS routing and referral parsing, ported from `runWhois`, `cleanWhoisServerUri` and
/// `extractReferralServer` in `ui/AppViewModel.kt`.
///
/// WHOIS is a two-step protocol in practice: the registry that answers first usually only knows
/// *who else* to ask. Everything here decides where to send a query and how to read that pointer out
/// of a free-text reply — no sockets, because that decision is the part worth testing exhaustively.
///
/// The reply is unstructured text from a server the user named, so the referral it contains is
/// **untrusted input that decides what this app connects to next**. It is validated as a hostname
/// before being used, and followed exactly once.
library;

/// Where a query starts.
///
/// An address goes to a regional registry; anything else goes to IANA, which knows which registry
/// owns each TLD and says so in its reply.
String initialWhoisServer(String target) =>
    looksLikeIpAddress(target) ? 'whois.arin.net' : 'whois.iana.org';

/// True for something that is an IP address rather than a name.
///
/// Deliberately structural rather than strict: this only chooses which server to ask first, and a
/// wrong guess costs one redundant hop, not a wrong answer.
bool looksLikeIpAddress(String target) {
  final trimmed = target.trim();
  if (trimmed.isEmpty) return false;
  if (trimmed.contains(':')) return _looksLikeIpv6(trimmed);

  final parts = trimmed.split('.');
  if (parts.length != 4) return false;
  return parts.every((part) {
    if (part.isEmpty || part.length > 3) return false;
    final value = int.tryParse(part);
    return value != null && value >= 0 && value <= 255;
  });
}

bool _looksLikeIpv6(String value) {
  // Enough to tell "2001:db8::1" from "example.com" — a full IPv6 grammar buys nothing here.
  final withoutZone = value.split('%').first;
  if (!withoutZone.contains(':')) return false;
  return RegExp(r'^[0-9a-fA-F:]+$').hasMatch(withoutZone) && withoutZone.contains('::') ||
      RegExp(r'^([0-9a-fA-F]{0,4}:){2,7}[0-9a-fA-F]{0,4}$').hasMatch(withoutZone);
}

/// Reduces a server reference to the bare host to connect to.
///
/// Registries write this field inconsistently: `whois://whois.nic.uk`, `whois.verisign-grs.com:43`,
/// `rwhois://rwhois.example.net:4321/`. All of them mean one host.
String cleanWhoisServerHost(String server) {
  var value = server.trim();
  for (final scheme in const ['whois://', 'rwhois://', 'http://', 'https://']) {
    if (value.toLowerCase().startsWith(scheme)) {
      value = value.substring(scheme.length);
      break;
    }
  }
  value = value.split('/').first;
  value = value.split(':').first;
  return value.trim();
}

/// A hostname this app is willing to open a socket to.
///
/// The referral comes from a remote reply, so it is checked rather than trusted: letters, digits,
/// dashes and dots only, at least one dot, and nothing that could be a path, a port, a space or a
/// second target. A reply that names something else is ignored and the first response stands.
bool isUsableWhoisHost(String host) {
  if (host.isEmpty || host.length > 253) return false;
  if (!host.contains('.')) return false;
  if (host.startsWith('.') || host.endsWith('.') || host.contains('..')) return false;
  return RegExp(r'^[A-Za-z0-9.-]+$').hasMatch(host) && !host.startsWith('-') && !host.endsWith('-');
}

/// The keys registries use to point at the server that actually holds the record.
const _referralKeys = <String>[
  'refer',
  'ReferralServer',
  'whois',
  'whois server',
  'Registrar WHOIS Server',
];

/// The server [response] refers on to, or null when it holds the record itself.
///
/// Returns null for a referral that is not a usable hostname, so a malformed or hostile field
/// leaves the app showing the answer it already has rather than connecting somewhere unexpected.
String? extractReferralServer(String response) {
  for (final key in _referralKeys) {
    for (final line in response.split('\n')) {
      final trimmed = line.trim();
      if (!trimmed.toLowerCase().startsWith('${key.toLowerCase()}:')) continue;
      final value = trimmed.substring(key.length + 1).trim();
      if (value.isEmpty) continue;
      // A referral field with a space in it is malformed, and quietly keeping the first word would
      // be this app choosing which half to believe. A URL's path and port are different: stripping
      // those is what the field means, not a guess about it.
      if (RegExp(r'\s').hasMatch(value)) continue;
      final host = cleanWhoisServerHost(value);
      if (isUsableWhoisHost(host)) return host;
    }
  }
  return null;
}

/// What to write down the socket.
///
/// CRLF, not a bare newline: the protocol says so, and servers that tolerate `\n` are the exception
/// rather than the rule.
String whoisRequestLine(String target) => '${target.trim()}\r\n';
