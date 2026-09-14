import '../data/app_database.dart';

/// The protocols a saved share can speak, ported from `NetworkSharesTab` in `ui/SftpScreen.kt`.
///
/// Kept as an enum with its properties attached rather than a bare string list, because three
/// separate things are derived from the protocol — the default port, whether the share can be
/// browsed, and the URI scheme — and having them drift apart is how a share ends up saved on the
/// wrong port or offering a Browse button that cannot work.
enum ShareProtocol {
  smb('SMB', 445, 'smb'),
  ftp('FTP', 21, 'ftp'),
  sftp('SFTP', 22, 'sftp'),
  nfs('NFS', 2049, 'nfs'),
  webdav('WEBDAV', 443, 'https'),
  custom('CUSTOM', 0, '');

  const ShareProtocol(this.id, this.defaultPort, this.scheme);

  /// Stored verbatim in the database, matching what the Kotlin app wrote.
  final String id;
  final int defaultPort;
  final String scheme;

  String get label => this == ShareProtocol.webdav ? 'WebDAV' : id;

  static ShareProtocol fromId(String? value) {
    final wanted = (value ?? '').trim().toUpperCase();
    return ShareProtocol.values.firstWhere((p) => p.id == wanted, orElse: () => ShareProtocol.smb);
  }
}

/// Whether OmniTerm can open a file browser on this protocol.
///
/// **Narrower than the Kotlin's list on purpose.** The Kotlin browsed SMB, FTP, SFTP and WebDAV;
/// this port has clients for SMB (native, §7.1) and SFTP only. Offering Browse for FTP or WebDAV
/// here would be a button that fails on tap, which is worse than one that is honestly absent
/// (Convention 4). The gap is recorded in §18 rather than papered over.
bool shareIsBrowsable(ShareProtocol protocol) =>
    protocol == ShareProtocol.smb ||
    protocol == ShareProtocol.ftp ||
    protocol == ShareProtocol.sftp ||
    protocol == ShareProtocol.webdav;

/// Why a protocol cannot be browsed, in the user's terms.
String? shareBrowseUnavailableReason(ShareProtocol protocol) => switch (protocol) {
  ShareProtocol.smb || ShareProtocol.ftp || ShareProtocol.sftp || ShareProtocol.webdav => null,
  // NFS mounting is a kernel operation, not something an unprivileged app can do — this was
  // never browsable in the Kotlin either.
  ShareProtocol.nfs => 'NFS shares are mounted by the operating system, not by OmniTerm.',
  ShareProtocol.custom => 'A custom share has no protocol for OmniTerm to speak.',
};

/// A share as the form holds it: strings, because that is what text fields produce.
class NetworkShareDraft {
  const NetworkShareDraft({
    this.id = 0,
    this.name = '',
    this.protocol = ShareProtocol.smb,
    this.address = '',
    this.port = '',
    this.sharePath = '',
    this.workgroup = '',
    this.username = '',
    this.password = '',
    this.authProfileId,
    this.anonymous = false,
    this.useHttps = true,
    this.notes = '',
  });

  factory NetworkShareDraft.fromShare(NetworkShare share) => NetworkShareDraft(
    id: share.id,
    name: share.name,
    protocol: ShareProtocol.fromId(share.protocol),
    address: share.address,
    port: share.port > 0 ? '${share.port}' : '',
    sharePath: share.sharePath,
    workgroup: share.workgroup,
    username: share.username,
    password: share.password,
    authProfileId: share.authProfileId,
    anonymous: share.anonymous,
    useHttps: share.useHttps,
    notes: share.notes,
  );

  final int id;
  final String name;
  final ShareProtocol protocol;
  final String address;

  /// Blank means "use the protocol's default", which is resolved by [effectivePort].
  final String port;
  final String sharePath;
  final String workgroup;
  final String username;
  final String password;
  final int? authProfileId;
  final bool anonymous;
  final bool useHttps;
  final String notes;

  NetworkShareDraft copyWith({
    String? name,
    ShareProtocol? protocol,
    String? address,
    String? port,
    String? sharePath,
    String? workgroup,
    String? username,
    String? password,
    int? authProfileId,
    bool clearAuthProfile = false,
    bool? anonymous,
    bool? useHttps,
    String? notes,
  }) => NetworkShareDraft(
    id: id,
    name: name ?? this.name,
    protocol: protocol ?? this.protocol,
    address: address ?? this.address,
    port: port ?? this.port,
    sharePath: sharePath ?? this.sharePath,
    workgroup: workgroup ?? this.workgroup,
    username: username ?? this.username,
    password: password ?? this.password,
    authProfileId: clearAuthProfile ? null : (authProfileId ?? this.authProfileId),
    anonymous: anonymous ?? this.anonymous,
    useHttps: useHttps ?? this.useHttps,
    notes: notes ?? this.notes,
  );

  /// Switch protocol, moving the port with it when the old one was just the old default.
  ///
  /// A port the user typed is never overwritten — silently changing it is how a share stops
  /// reaching a NAS on a non-standard port with no visible cause.
  NetworkShareDraft withProtocol(ShareProtocol next) {
    final wasDefault = port.trim().isEmpty || int.tryParse(port.trim()) == protocol.defaultPort;
    return copyWith(
      protocol: next,
      port: wasDefault ? (next.defaultPort > 0 ? '${next.defaultPort}' : '') : null,
      // Switching to SFTP with anonymous already on would leave the draft invalid behind a toggle
      // that is disabled for SFTP — unfixable without switching protocol back. Compose clears it on
      // the same transition (`ui/SftpScreen.kt:1389`).
      anonymous: next == ShareProtocol.sftp ? false : null,
    );
  }

  int get effectivePort {
    final typed = int.tryParse(port.trim());
    if (typed != null && typed > 0) return typed;
    return protocol.defaultPort;
  }

  /// Validation messages keyed by field, empty when the draft can be saved.
  Map<String, String> get errors {
    final found = <String, String>{};
    if (name.trim().isEmpty) found['name'] = 'Give this share a name.';
    if (address.trim().isEmpty) {
      found['address'] = 'An address or hostname is required.';
    }

    final typed = port.trim();
    if (typed.isNotEmpty) {
      final parsed = int.tryParse(typed);
      if (parsed == null || parsed < 1 || parsed > 65535) {
        found['port'] = 'A port is a number from 1 to 65535.';
      }
    } else if (protocol.defaultPort == 0) {
      // Only CUSTOM has no default to fall back on.
      found['port'] = 'A custom share needs an explicit port.';
    }

    if (protocol == ShareProtocol.smb && sharePath.trim().isEmpty) {
      // SMB connects to a *share*, not to a host; without one there is nothing to open.
      found['sharePath'] = 'SMB needs a share name.';
    }
    // SFTP is SSH, and SSH has no anonymous mode: a share saved this way can never connect, and
    // the form has just hidden the username field that would have fixed it. Compose refuses the
    // same combination at `ui/SftpScreen.kt:1351`.
    if (protocol == ShareProtocol.sftp && anonymous) {
      found['anonymous'] = 'SFTP needs a username or credential profile.';
    }
    if (!anonymous && authProfileId == null && username.trim().isEmpty) {
      found['username'] = 'Enter a username, pick a credential profile, or tick anonymous.';
    }
    return found;
  }

  bool get isValid => errors.isEmpty;

  /// Advisory notes — true, worth saying, and never a reason to refuse the save (§17).
  List<String> get warnings {
    final notes = <String>[];
    if (protocol == ShareProtocol.ftp && !anonymous) {
      notes.add(
        'FTP sends the password in clear text. Anyone on the path between this device and the '
        'server can read it. Prefer SFTP where the server offers it.',
      );
    }
    if (protocol == ShareProtocol.webdav && !useHttps) {
      notes.add('Without HTTPS, WebDAV sends the password in clear text on every request.');
    }
    if (protocol == ShareProtocol.smb && anonymous) {
      notes.add('Anonymous SMB only works where the server has guest access enabled.');
    }
    return notes;
  }

  /// The row to persist. The repository encrypts the password on the way down.
  NetworkShare toShare({int lastChecked = 0, String lastStatus = 'unknown'}) => NetworkShare(
    id: id,
    name: name.trim(),
    protocol: protocol.id,
    address: address.trim(),
    port: effectivePort,
    sharePath: sharePath.trim(),
    workgroup: workgroup.trim(),
    // Anonymous means anonymous: keeping the typed credentials on the row would leave a
    // password stored for a share that never sends one.
    username: anonymous ? '' : username.trim(),
    password: anonymous ? '' : password,
    authProfileId: anonymous ? null : authProfileId,
    anonymous: anonymous,
    useHttps: useHttps,
    notes: notes.trim(),
    lastChecked: lastChecked,
    lastStatus: lastStatus,
  );
}

/// A display URI for a saved share, e.g. `smb://nas.local:445/media`.
///
/// Never includes the username or password: this appears on a list the user may be showing someone.
String shareUri(NetworkShare share, {String? maskedAddress}) {
  final protocol = ShareProtocol.fromId(share.protocol);
  final scheme = protocol == ShareProtocol.webdav
      ? (share.useHttps ? 'https' : 'http')
      : (protocol.scheme.isEmpty ? share.protocol.toLowerCase() : protocol.scheme);
  final port = share.port > 0 ? ':${share.port}' : '';
  final trimmed = share.sharePath.replaceAll(RegExp(r'^/+|/+$'), '');
  final path = trimmed.isEmpty ? '' : '/$trimmed';
  return '$scheme://${maskedAddress ?? share.address}$port$path';
}
