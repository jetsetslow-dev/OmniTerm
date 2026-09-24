/// What a backup includes, and the rules that keep the result restorable.
///
/// The interesting part is not the flags but the **closure**: several sections point at others, and
/// a backup whose child rows reference parents that were not exported restores into dangling
/// references. Normalising here rather than in the UI means a programmatic export or a persisted
/// selection cannot produce one either.
library;

/// The sections a backup can carry.
enum BackupSection {
  servers('Hosts'),
  sshKeys('SSH keys'),
  credentialProfiles('Credential profiles'),
  scripts('Scripts'),
  alertRules('Alert rules'),
  activeAlerts('Firing alerts'),
  alertHistory('Alert history'),
  wolTargets('Wake-on-LAN targets'),
  networkShares('Network shares'),
  portForwards('Port forwards'),
  settings('Settings'),
  crashLogs('Crash logs *');

  const BackupSection(this.label);

  final String label;
}

/// An immutable set of selected sections.
class BackupSelection {
  const BackupSelection(this._selected);

  /// Everything, which is what a user almost always wants from a backup.
  BackupSelection.all({bool includeCrashLogs = false})
    : _selected = BackupSection.values
          .where((section) => includeCrashLogs || section != BackupSection.crashLogs)
          .toSet();

  const BackupSelection.none() : _selected = const {};

  final Set<BackupSection> _selected;

  bool contains(BackupSection section) => _selected.contains(section);

  Set<BackupSection> get sections => Set.unmodifiable(_selected);

  bool get isEmpty => _selected.isEmpty;

  /// Sections that must also be included for [section]'s rows to resolve on restore.
  ///
  /// Alert rules, incidents, history and port forwards are all scoped to a host; an incident is
  /// additionally scoped to the rule that raised it. Restoring any of them without its parent would
  /// produce a row pointing at an id that no longer exists.
  static Set<BackupSection> dependenciesOf(BackupSection section) => switch (section) {
    BackupSection.alertRules => {BackupSection.servers},
    BackupSection.activeAlerts => {BackupSection.servers, BackupSection.alertRules},
    BackupSection.alertHistory => {BackupSection.servers},
    BackupSection.portForwards => {BackupSection.servers},
    _ => const {},
  };

  /// Sections that cannot survive without [section].
  static Set<BackupSection> dependentsOf(BackupSection section) => {
    for (final candidate in BackupSection.values)
      if (dependenciesOf(candidate).contains(section)) candidate,
  };

  /// Adds every dependency the current selection implies.
  BackupSelection withReferentialClosure() {
    final closed = Set<BackupSection>.from(_selected);
    // Repeated until stable: an incident pulls in its rule, which in turn pulls in the host.
    var changed = true;
    while (changed) {
      changed = false;
      for (final section in Set<BackupSection>.from(closed)) {
        for (final dependency in dependenciesOf(section)) {
          if (closed.add(dependency)) changed = true;
        }
      }
    }
    return BackupSelection(closed);
  }

  /// Turns [section] on (pulling in its dependencies) or off (dropping what depends on it).
  ///
  /// Both directions matter: enabling incidents without their rules gives an unrestorable backup,
  /// and disabling hosts while leaving alert rules selected gives the same thing from the other end.
  /// Wire prefix for the current encoding, matching Kotlin's `BACKUP_SELECTION_V2_PREFIX`.
  static const _v2Prefix = 'v2:';

  /// Serialises the selection for `backup_export_selection`.
  ///
  /// Byte-compatible with Kotlin's `BackupSelection.encode()`: the `v2:` prefix followed by the
  /// enabled section names, comma-separated. The names are the enum's own, which already match
  /// Kotlin's keys exactly, so a selection written by the Android app is read back unchanged here.
  String encode() {
    final closed = withReferentialClosure();
    return _v2Prefix +
        BackupSection.values.where(closed.contains).map((section) => section.name).join(',');
  }

  /// Reads a stored selection back, defaulting to everything but crash logs.
  ///
  /// **A v1 value — one with no `v2:` prefix — predates tunnel backup.** Kotlin inherits
  /// `portForwards` from `servers` in that case, and this does the same: a legacy settings-only
  /// selection must not silently start exporting host data on first launch after an upgrade.
  ///
  /// An unrecognised name is ignored rather than failing the whole parse, so a selection written by
  /// a newer build degrades to the sections this one understands instead of resetting entirely.
  static BackupSelection decode(String? value) {
    final raw = value?.trim() ?? '';
    if (raw.isEmpty) return BackupSelection.all();
    final isV2 = raw.startsWith(_v2Prefix);
    final body = isV2 ? raw.substring(_v2Prefix.length) : raw;
    final names = body
        .split(',')
        .map((name) => name.trim())
        .where((name) => name.isNotEmpty)
        .toSet();

    final selected = <BackupSection>{
      for (final section in BackupSection.values)
        if (names.contains(section.name)) section,
    };
    if (!isV2 && names.contains(BackupSection.servers.name)) {
      selected.add(BackupSection.portForwards);
    }
    return BackupSelection(selected).withReferentialClosure();
  }

  BackupSelection toggled(BackupSection section, {required bool enabled}) {
    if (enabled) {
      return BackupSelection({..._selected, section}).withReferentialClosure();
    }
    final removed = <BackupSection>{section};
    var changed = true;
    while (changed) {
      changed = false;
      for (final dependent in BackupSection.values) {
        if (removed.contains(dependent)) continue;
        if (dependenciesOf(dependent).any(removed.contains)) {
          removed.add(dependent);
          changed = true;
        }
      }
    }
    return BackupSelection(_selected.difference(removed));
  }

  /// True when the backup would contain credentials or anything that identifies a host.
  ///
  /// Drives the requirement to encrypt: hosts carry passwords, keys carry private material, and
  /// even scripts and alert rules name machines and paths. Settings alone are the only selection
  /// with nothing worth protecting — and the UI still offers encryption there.
  bool get hasSensitiveData => _selected.any(
    (section) => switch (section) {
      BackupSection.servers ||
      BackupSection.sshKeys ||
      BackupSection.credentialProfiles ||
      BackupSection.scripts ||
      BackupSection.alertRules ||
      BackupSection.activeAlerts ||
      BackupSection.alertHistory ||
      BackupSection.networkShares ||
      BackupSection.portForwards => true,
      BackupSection.crashLogs => true,
      BackupSection.wolTargets || BackupSection.settings => false,
    },
  );

  @override
  bool operator ==(Object other) =>
      other is BackupSelection &&
      other._selected.length == _selected.length &&
      other._selected.containsAll(_selected);

  @override
  int get hashCode => Object.hashAllUnordered(_selected);
}

/// Resolves a backed-up host id to its restored one.
///
/// Zero is preserved: it is the fleet-wide scope, not a real host, and remapping it would turn a
/// rule that watches every machine into one that watches whichever host happened to restore first.
/// Any other id with no mapping returns null, and the caller drops that row rather than pointing it
/// somewhere arbitrary.
int? remapServerId(int oldServerId, Map<int, int> serverIdMap) =>
    oldServerId == 0 ? 0 : serverIdMap[oldServerId];

/// How many hosts a restore may bring in, given the build's entitlement.
///
/// Ported from `maxSelected` on `BackupHostSelectionList` (`ui/ToolsScreen.kt:2970`).
///
/// The free Play build caps *saved hosts*, and that cap is enforced when adding one by hand. A
/// restore writes host rows too, so without the same cap a backup is an unmetered way straight past
/// it — the same shape as Kotlin's note that ad-hoc connections must not bypass the saved-host
/// limit. Null means no cap, which is the source-available build and any unlocked install.
int? restoreHostCap({required bool hasHostLimit, required int hostLimit}) =>
    hasHostLimit ? hostLimit : null;

/// The hosts a restore should start with selected.
///
/// **The first [cap] in the file's own order**, not an arbitrary subset: the order a backup lists
/// hosts in is the order they were saved, so the oldest survive a capped restore. Choosing by
/// anything else would be choosing for the user, and they can change the selection anyway.
Set<int> defaultRestoreHostIds(Iterable<int> hostIds, {int? cap}) {
  final all = hostIds.toList();
  if (cap == null || all.length <= cap) return all.toSet();
  return all.take(cap < 0 ? 0 : cap).toSet();
}
