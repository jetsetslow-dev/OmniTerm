# App Store readiness and privacy evidence

This is the release evidence checklist, not a claim that an archive has passed validation.

| Area | Current declaration / product behavior | Evidence required before submission |
|---|---|---|
| Privacy manifest | Empty shell declares no tracking, collected data, or required-reason APIs | Regenerate after every SDK addition; archive validation and dependency manifests decide final entries. |
| Local network | Used only for user-configured hosts | Usage string, denial-state screenshot, clean-install device test. |
| Notifications | Optional alerts; denial leaves in-app alerts usable | Permission, masking, tap-route, and resolution-cleanup tests. |
| Biometrics | Optional app/secret protection; cancellation never unlocks | Usage string, cancellation/fallback tests, lifecycle teardown evidence. |
| Files | User-selected import/export and bounded previews | Security-scoped URL lifetime, incomplete cleanup, large streaming evidence. |
| Clipboard | Explicit copy/paste; terminal contents are not diagnostics | Privacy copy, paste permission, and incognito-keyboard paste test. |
| Tracking/ads | Not enabled in the iOS shell | If added, update ATT, consent, labels, manifest, and ADR first. |
| Cryptography | SSH/SFTP/TLS product features | Export-compliance answers reviewed by owner; do not infer exemption in code. |
| Background | tmux persists; iOS reconnects and never promises indefinite SSH | Review notes/screenshots use this behavior; cached monitoring is labeled stale. |
| Purchases | No iOS SKU wired | Decision, restore flow, sandbox evidence, entitlement parity. |
| Accessibility | Compose Multiplatform UI | VoiceOver, scaling, keyboard, contrast, reduced-motion, and switch-control matrix. |
| Support/privacy | Not assigned | Public support/privacy URLs, deletion/retention statement, contact owner. |

Release is incomplete until a signed archive passes Xcode validation with no unresolved privacy or
signing warnings and the store listing matches implemented behavior.
