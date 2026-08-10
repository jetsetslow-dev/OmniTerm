/// The free-tier saved-host limit, and what to do when an install is already over it.
///
/// Ported from `reconcileHostLimit` and `updateLicenseEntitlement` (`ui/AppViewModel.kt:928`,
/// `:966`).
///
/// Defect 51 closed the route that *creates* the condition — a restore that ignored the cap. This is
/// the other half: an install that is already holding too many, which a restore on an older build,
/// a lapsed subscription, or a refund can all produce. Blocking new hosts does nothing about hosts
/// already saved.
library;

/// Why a reconciliation is being asked for.
///
/// Two reasons rather than one because they are different situations and the wording has to say so:
/// a user whose unlock has ended is being told something has changed, while a user who has always
/// been on the free tier is being told what it allows.
enum HostLimitReason {
  /// The entitlement lapsed while more hosts than the free tier allows were saved.
  unlockEnded,

  /// The install has always been limited — typically after restoring a larger backup.
  freeTier,
}

extension HostLimitReasonMessage on HostLimitReason {
  String message(int limit) {
    final hosts = limit == 1 ? 'host' : 'hosts';
    return switch (this) {
      HostLimitReason.unlockEnded =>
        'Your full unlock is no longer active. Choose the $limit saved $hosts to keep.',
      HostLimitReason.freeTier =>
        'This build saves $limit $hosts. Choose which to keep.',
    };
  }
}

/// Whether the install is holding more saved hosts than its entitlement allows.
///
/// False whenever there is no limit, so the source-available build and any unlocked install never
/// see this at all.
bool hostLimitExceeded({
  required bool hasHostLimit,
  required int hostLimit,
  required int hostCount,
}) => hasHostLimit && hostCount > hostLimit;

/// Whether a chosen set of hosts to keep is a legal answer.
///
/// **Exactly the limit, not at most.** Keeping fewer would be the app deleting hosts the user never
/// asked it to delete, and keeping none would leave an install with nothing in it — neither is a
/// reconciliation, and both are silently destructive.
bool isValidHostKeepSelection({
  required int selectedCount,
  required int hostLimit,
}) => selectedCount == hostLimit;

/// Whether the reconciliation surface should be shown at all.
///
/// Pure, because the widget's own branches are **not testable in the host suite**:
/// `isPlayStoreDistribution` is a compile-time constant and the tests build source-available, so a
/// widget test of the gate passes on the early return no matter what the entitlement says. Keeping
/// the decision here is what makes it possible to check the cases that matter.
///
/// [licenseLoading] suppresses it while the store query is in flight: acting then would put a
/// deletion prompt in front of a paying user in the seconds before their unlock is confirmed.
bool shouldReconcileHostLimit({
  required bool playStoreBuild,
  required bool licenseEnabled,
  required bool licenseLoading,
  required bool unlocked,
  required int hostLimit,
  required int hostCount,
}) {
  if (!playStoreBuild || !licenseEnabled || licenseLoading || unlocked) {
    return false;
  }
  return hostLimitExceeded(
    hasHostLimit: true,
    hostLimit: hostLimit,
    hostCount: hostCount,
  );
}
