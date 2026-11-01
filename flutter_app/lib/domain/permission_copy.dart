/// Copy for the runtime-permission prompts.
///
/// Held here rather than inline in the dialog because the dialogs themselves are unreachable from
/// the host suite: the permission probes fall back to "not required" when the platform channel is
/// absent, so nothing renders and any widget test would pass without asserting anything.
///
/// What is worth pinning is not the wording but a *property* — that a consent prompt says what
/// declining costs, not only what accepting buys.
library;

/// Ported from `local_network_access_explanation` (`res/values/strings.xml:33`).
///
/// The final sentence was missing from the Flutter port. Without it the dialog explained what the
/// permission is for and left "Not now" looking free, on a prompt the user cannot easily get back
/// to once dismissed.
const String localNetworkPermissionExplanation =
    'Android requires permission before OmniTerm can connect directly to hosts on '
    'Wi-Fi or Ethernet. This is used for SSH, files, monitoring, LAN discovery, '
    'tunnels, shares, and Wake-on-LAN.\n\n'
    'If you choose Not now, internet hosts remain available but nearby-device '
    'features may not work.';
