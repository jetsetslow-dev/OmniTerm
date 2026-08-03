import 'package:drift/drift.dart' show Value;
import 'package:flutter/foundation.dart';

import '../../../data/app_database.dart';

/// How the add/edit sheet was opened.
enum ServerFormMode {
  /// A brand-new host.
  add,

  /// Editing a saved host. Stored secrets are **never** loaded into the form.
  edit,

  /// A copy of an existing host. Secrets *are* seeded — that is the point of "reuse credentials" —
  /// but the save goes through the add path as an independent new host, so the first-connect
  /// host-key trust gate applies exactly as it would to any new host.
  duplicate,
}

/// The add/edit/duplicate form's logic, extracted from `AddServerSheet` in `ui/AppUi.kt`.
///
/// Kept separate from the widget because two of its rules are security controls rather than
/// presentation, and both need to be testable directly:
///
/// 1. **Stored secrets never reach the form.** On an edit the password fields start empty and an
///    empty field means "keep the saved value"; the matching `forget…` flag means "remove it". A
///    saved password is therefore never rendered into a text field where it could be
///    shoulder-surfed, screenshotted, or read out by an accessibility service.
/// 2. **Saving requires a passing connection test for the *current* configuration.** The
///    [connectionSignature] fingerprints every connection-relevant field, so changing a host,
///    credential or proxy invalidates a previous pass — which is what stops the first-connect
///    host-key approval from being skipped by editing a tested host. Cosmetic edits (name, group,
///    colour, notes) deliberately do **not** force a retest.
class ServerFormState extends ChangeNotifier {
  ServerFormState({
    required this.mode,
    Server? source,
    String? prefillHost,
    int? prefillPort,
    String? suggestedName,
  })  : _editing = mode == ServerFormMode.edit ? source : null,
        _duplicateSource = mode == ServerFormMode.duplicate ? source : null {
    final src = source;
    name = switch (mode) {
      ServerFormMode.duplicate => '${src?.name} copy',
      ServerFormMode.edit => src?.name ?? '',
      ServerFormMode.add => suggestedName ?? '',
    };
    host = src?.host ?? prefillHost ?? '';
    port = (src?.port ?? prefillPort ?? 22).toString();
    username = src?.username ?? '';
    group = src?.groupName ?? 'Default';
    serverColor = src?.serverColor ?? 'Default';
    authType = src?.authType ?? 'password';
    selectedKeyAlias = src?.authKeyAlias ?? '';
    selectedProfileId = src?.authProfileId;
    notes = src?.notes ?? '';
    keepAlive = (src?.keepAlive ?? 30).toString();
    compression = src?.sshCompression ?? false;
    persistentSession = src?.persistentSession ?? false;
    agentForwarding = src?.agentForwarding ?? false;
    proxyType = src?.proxyType ?? 'none';
    proxyHost = src?.proxyHost ?? '';
    final srcProxyPort = src?.proxyPort ?? 0;
    proxyPort = srcProxyPort > 0 ? srcProxyPort.toString() : '';
    proxyUser = src?.proxyUser ?? '';
    proxyKeyAlias = src?.proxyKeyAlias ?? '';

    // Only a duplicate seeds secrets; an edit starts blank so nothing stored is displayed.
    final dup = _duplicateSource;
    password = dup?.authPassword ?? '';
    sudoPassword = dup?.sudoPassword ?? '';
    proxyPassword = dup?.proxyPassword ?? '';

    // An existing host's saved configuration counts as already tested, so editing its name does not
    // demand a fresh round trip to the server.
    _testedOkSignature = _editing != null ? connectionSignature : null;
  }

  final ServerFormMode mode;
  final Server? _editing;
  final Server? _duplicateSource;

  Server? get editing => _editing;

  late String name;
  late String host;
  late String port;
  late String username;
  late String group;
  late String serverColor;
  late String authType;
  late String selectedKeyAlias;
  int? selectedProfileId;
  late String notes;
  late String keepAlive;
  late bool compression;
  late bool persistentSession;
  late bool agentForwarding;
  late String proxyType;
  late String proxyHost;
  late String proxyPort;
  late String proxyUser;
  late String proxyKeyAlias;

  /// Typed secrets. Empty means "unchanged" on an edit — never "blank it out".
  late String password;
  late String sudoPassword;
  late String proxyPassword;

  /// Explicit "remove the stored secret" flags, the only way to clear one.
  bool forgetPassword = false;
  bool forgetSudoPassword = false;
  bool forgetProxyPassword = false;

  bool get hasStoredPassword => (_editing?.authPassword ?? '').isNotEmpty;
  bool get hasStoredSudoPassword => (_editing?.sudoPassword ?? '').isNotEmpty;
  bool get hasStoredProxyPassword => (_editing?.proxyPassword ?? '').isNotEmpty;

  String? _testedOkSignature;

  void update(VoidCallback change) {
    change();
    notifyListeners();
  }

  // ── secret resolution ──────────────────────────────────────────────────────
  //
  // Typed text wins; otherwise the stored value is kept unless the user asked to forget it. Also
  // used by Test Connection, so a blank field (= keep saved) still tests with the real credential
  // rather than silently testing with none.

  String get effectivePassword {
    if (password.isNotEmpty) return password;
    if (forgetPassword) return '';
    return _editing?.authPassword ?? '';
  }

  String get effectiveSudoPassword {
    if (sudoPassword.isNotEmpty) return sudoPassword;
    if (forgetSudoPassword) return '';
    return _editing?.sudoPassword ?? '';
  }

  String get effectiveProxyPassword {
    if (proxyPassword.isNotEmpty) return proxyPassword;
    if (forgetProxyPassword) return '';
    return _editing?.proxyPassword ?? '';
  }

  // ── the connection-test gate ───────────────────────────────────────────────

  /// A fingerprint of every field that affects how the connection is made.
  ///
  /// NUL-joined so a value containing the separator cannot forge a different field's boundary.
  String get connectionSignature => [
        host.trim(),
        port,
        username,
        authType,
        effectivePassword,
        selectedKeyAlias,
        selectedProfileId?.toString() ?? '',
        proxyType,
        proxyHost.trim(),
        proxyPort,
        proxyUser,
        effectiveProxyPassword,
        proxyKeyAlias,
      ].join('\u0000');

  /// Records that Test Connection succeeded for the configuration as it stands right now.
  void markConnectionTested() {
    _testedOkSignature = connectionSignature;
    notifyListeners();
  }

  /// True when the current configuration has not passed a connection test.
  ///
  /// This is the host-key gate: an untested configuration cannot be saved, so a new host's key must
  /// have been presented and approved first.
  bool get requiresConnectionTest => _testedOkSignature != connectionSignature;

  // ── validation ─────────────────────────────────────────────────────────────

  /// The first validation failure, or null when the form can be saved.
  String? get validationError {
    if (name.trim().isEmpty) return 'Name is required';
    if (host.trim().isEmpty) return 'Host is required';
    if (username.trim().isEmpty) return 'Username is required';

    final portValue = int.tryParse(port.trim());
    if (portValue == null || portValue < 1 || portValue > 65535) {
      return 'Port must be 1-65535';
    }
    final keepAliveValue = int.tryParse(keepAlive.trim());
    if (keepAliveValue == null || keepAliveValue < 0) return 'Keepalive must be 0 or more';

    if (proxyType != 'none') {
      if (proxyHost.trim().isEmpty) return 'Proxy host is required';
      final proxyPortValue = int.tryParse(proxyPort.trim());
      if (proxyPortValue == null || proxyPortValue < 1 || proxyPortValue > 65535) {
        return 'Proxy port must be 1-65535';
      }
    }
    return null;
  }

  bool get canSave => validationError == null && !requiresConnectionTest;

  // ── building the row ───────────────────────────────────────────────────────

  /// The row to persist.
  ///
  /// For an edit this carries the existing id so the repository updates in place; for add and
  /// duplicate the id is 0, which the repository turns into a fresh auto-generated key.
  Server toServer() {
    final existing = _editing;
    return Server(
      id: existing?.id ?? 0,
      name: name.trim(),
      host: host.trim(),
      port: int.tryParse(port.trim()) ?? 22,
      username: username.trim(),
      groupName: group,
      serverColor: serverColor,
      authType: authType,
      authKeyAlias: selectedKeyAlias.isEmpty ? null : selectedKeyAlias,
      authPassword: effectivePassword,
      sudoPassword: effectiveSudoPassword,
      authProfileId: selectedProfileId,
      notes: notes,
      keepAlive: int.tryParse(keepAlive.trim()) ?? 30,
      sshCompression: compression,
      persistentSession: persistentSession,
      proxyCommand: '',
      proxyType: proxyType,
      proxyHost: proxyHost.trim(),
      proxyPort: int.tryParse(proxyPort.trim()) ?? 0,
      proxyUser: proxyUser,
      proxyPassword: effectiveProxyPassword,
      // Only meaningful for a jump host; keeping it otherwise would apply a key to an HTTP proxy.
      proxyKeyAlias:
          (proxyKeyAlias.trim().isNotEmpty && proxyType == 'ssh') ? proxyKeyAlias : null,
      agentForwarding: agentForwarding,
      // A new or duplicated host starts unprobed rather than inheriting the source's health.
      healthScore: existing?.healthScore ?? 100,
      lastLatency: existing?.lastLatency ?? 0,
      status: existing?.status ?? 'offline',
      authStatus: existing?.authStatus ?? 'unknown',
      authError: existing?.authError,
    );
  }

  /// Group labels offered by the picker: "Default" plus every label already in use, so a typo
  /// cannot silently fork a near-duplicate group.
  static List<String> groupOptions(List<Server> servers) {
    final groups = <String>['Default'];
    for (final server in servers) {
      final group = server.groupName;
      if (group != null && group.isNotEmpty && !groups.contains(group)) groups.add(group);
    }
    return groups;
  }

  /// Convenience for callers updating a nullable column through Drift's [Value] wrapper.
  static Value<T> valueOrAbsent<T>(T? value) =>
      value == null ? const Value.absent() : Value(value);
}
