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

/// Whether OmniTerm can open a file browser on this protocol: Kotlin's `isShareBrowsable`. NFS
/// mounting is a kernel operation an unprivileged app cannot do, and a custom share has no protocol
/// to speak, so neither is browsable in either app.
bool shareIsBrowsable(ShareProtocol protocol) =>
    protocol == ShareProtocol.smb ||
    protocol == ShareProtocol.ftp ||
    protocol == ShareProtocol.sftp ||
    protocol == ShareProtocol.webdav;

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
      // Kotlin turns HTTPS on when WebDAV is picked; it stays the user's to change.
      useHttps: next == ShareProtocol.webdav ? true : null,
    );
  }

  int get effectivePort {
    final typed = int.tryParse(port.trim());
    if (typed != null && typed > 0) return typed;
    return protocol.defaultPort;
  }

  /// Why the draft cannot be saved, in Kotlin's words and order (`validateDraft` in
  /// `ui/SftpScreen.kt`), or null. The form shows the first problem only, as Kotlin does.
  String? get validationError {
    final typedPort = int.tryParse(port.trim());
    if (address.trim().isEmpty) return 'Address is required.';
    if (protocol != ShareProtocol.custom &&
        (typedPort == null || typedPort < 1 || typedPort > 65535)) {
      return 'Port must be between 1 and 65535.';
    }
    if (protocol == ShareProtocol.smb &&
        sharePath.trim().replaceAll(RegExp(r'^/+|/+$'), '').isEmpty) {
      return 'SMB needs a Share/path value such as Public or Media.';
    }
    // SFTP is SSH, and SSH has no anonymous mode: a share saved this way could never connect.
    if (protocol == ShareProtocol.sftp && anonymous) {
      return 'SFTP needs a username or credential profile.';
    }
    if (!anonymous && authProfileId == null && username.trim().isEmpty) {
      return 'Username is required when anonymous login is off and no profile is selected.';
    }
    return null;
  }

  bool get isValid => validationError == null;

  /// Kotlin's FTP note, shown when credentials will be sent: advice, never a reason to refuse.
  bool get warnsFtpCleartext => protocol == ShareProtocol.ftp && !anonymous;

  /// Kotlin's WebDAV note for "Use HTTPS" off with a password to send.
  bool get warnsWebDavCleartext => protocol == ShareProtocol.webdav && !useHttps && !anonymous;

  /// Kotlin's `persistNetworkShare` normalisation. The repository encrypts the password.
  NetworkShare toShare({
    int lastChecked = 0,
    String lastStatus = 'unknown',
    int? createdProfileId,
  }) {
    final name = this.name.trim().isEmpty
        ? '${protocol.id.toLowerCase()}://${address.trim()}'
        : this.name.trim();
    final profileId = anonymous ? null : (createdProfileId ?? authProfileId);
    // Anonymous, or a credential profile, means the row itself keeps no username or password.
    final keepsCredentials = !anonymous && profileId == null;
    return NetworkShare(
      id: id,
      name: name,
      protocol: protocol.id,
      address: address.trim(),
      port: effectivePort,
      sharePath: sharePath.trim().replaceAll(RegExp(r'^/+'), ''),
      workgroup: workgroup.trim(),
      username: keepsCredentials ? username.trim() : '',
      password: keepsCredentials ? password : '',
      authProfileId: profileId,
      anonymous: anonymous,
      useHttps: protocol == ShareProtocol.webdav && useHttps,
      notes: notes.trim(),
      lastChecked: lastChecked,
      lastStatus: lastStatus,
    );
  }

  /// Kotlin saves typed credentials as a reusable profile in the "Network Shares" group and points
  /// the share at it. Null when nothing is typed or a profile is already chosen.
  CredentialProfile? get profileToCreate {
    if (anonymous || authProfileId != null || username.trim().isEmpty) return null;
    final label = name.trim().isEmpty ? '${protocol.id} ${address.trim()}' : name.trim();
    return CredentialProfile(
      id: 0,
      profileName: 'Network Share - $label',
      username: username.trim(),
      authType: 'password',
      password: password,
      groupName: 'Network Shares',
    );
  }
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
