/// Compile-time distribution switch.
///
/// Source builds stay fully unlocked. Store builds must opt in explicitly with
/// `--dart-define=OMNITERM_PLAY_STORE=true`; this prevents an unsigned developer build from
/// accidentally presenting billing or ads.
const bool isPlayStoreDistribution = bool.fromEnvironment(
  'OMNITERM_PLAY_STORE',
  defaultValue: false,
);
