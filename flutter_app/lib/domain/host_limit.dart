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
bool isValidHostKeepSelection({required int selectedCount, required int hostLimit}) =>
    selectedCount == hostLimit;
