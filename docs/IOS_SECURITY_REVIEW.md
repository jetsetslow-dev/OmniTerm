# OmniTerm iOS security and privacy review (IOS-091)

Status: **partial**. This records the threat model and the disposition of findings for the shared
code that exists today on `feature/ios-compose-port`. It is not a release sign-off: the areas that
depend on an unchosen SSH engine, on Keychain behavior, and on a signed build are listed as open and
must be reviewed again before beta (IOS-094).

Last updated: 2026-08-01.

## 1. Scope reviewed

- Shared terminal/session orchestration (`TerminalStore`) and host-key trust (`HostKeyTrust`).
- Shared files/transfers orchestration (`FilesStore`, `LocalFileGateway` contract).
- Shared secret handling (`SecretVault`, `SecretStorage` contract).
- Shared widget snapshot policy and cross-platform backup transfer.
- Existing shared diagnostics/redaction (`redactDiagnostic`, `RedactingDiagnosticLogger`) and
  notification safety policies.

Explicitly **out of scope** here: any Kotlin/Native or Swift implementation of Keychain,
LocalAuthentication, UserNotifications, WidgetKit, SSH, or SFTP — none of which has been executed on
an Apple runtime (see `IOS_TEST_MATRIX.md`).

## 2. Threat model

| Actor | Capability assumed | Primary concern |
|---|---|---|
| Malicious or compromised server | Full control of the byte stream, host key, SFTP responses, and file sizes | Terminal escape abuse, host-key substitution, path traversal on download, memory exhaustion |
| Network attacker | On-path interception and connection reset | Host-key substitution, downgrade, silent reconnect to a different endpoint |
| Local attacker with the unlocked device | App UI access | Reading stored credentials, exporting a backup, bypassing read-only mode |
| Local attacker with the locked device | File system access to app container and backups | Secrets at rest, database and WAL protection class, App Group exposure |
| Another app on the device | Reads shared containers, clipboard, notifications | Widget snapshot contents, notification body, clipboard residue |
| Curious observer | Sees lock screen and screenshots | Host identity leakage under privacy mode |

## 3. Findings and disposition

| # | Finding | Severity | Disposition |
|---|---|---|---|
| 1 | A slow connect completing after the user switched hosts could attach a session for the wrong host | High | **Fixed.** The store now refuses a second connect while one is in flight, as Android does, so two half-opened channels can never race; `CancelConnect` is the escape hatch and a shell that arrives after it is closed, not attached. |
| 2 | Host-key trust keyed on hostname alone would let `Host.example` and `host.example` hold separate records, hiding a changed key | Medium | **Fixed.** `hostKeyAlias` lower-cases the host and includes the port; covered by `aliasSeparatesPortsAndIgnoresHostnameCase`. |
| 3 | Malformed or MD5 fingerprints could be persisted, turning every later connection into a fresh "unknown host" prompt users learn to accept | Medium | **Fixed.** `hostKeyProblem` rejects them at evaluation *and* at write time. |
| 4 | Algorithm change with a matching fingerprint string would read as trusted | Medium | **Fixed.** Algorithm is part of the comparison. |
| 5 | Read-only terminal mode enforced only in the UI can be bypassed by paste, hardware keyboard, or an accessory bar | High | **Fixed.** Enforcement is in `TerminalStore.sendInput`, below every view; covered by `readOnlySessionDropsInputBelowTheUiLayer`. |
| 6 | A cancelled download leaving a partial file that reads as complete | Medium | **Fixed.** Cleanup runs under `NonCancellable`, closes the sink and discards the partial file. |
| 7 | Skipping a name conflict deleted the user's existing file (found by the conflict test during implementation) | High | **Fixed.** Only a destination this transfer opened may be discarded. |
| 8 | A secret revealed after a cancelled biometric prompt | Critical if shipped | **Fixed.** `SecretVault.reveal` returns the authentication failure before touching storage; covered by `failedAuthenticationNeverReachesStorage`. |
| 9 | A missing Keychain item returning "no secret" and silently downgrading to an unauthenticated attempt | Medium | **Fixed.** Missing items are `PlatformError.NotFound`. |
| 10 | Secret values or key names reaching diagnostics | High | **Fixed.** `SecretVault` logs only event names and a rotation flag; `SecretRef.toString()` is opaque. |
| 11 | Widget snapshot carrying endpoint, user, or metric detail into a shared container | High | **Fixed.** `WidgetHostLine` has no endpoint fields at all: like Android, a row names its host by the name its owner typed, never by an address. |
| 11a | Shared backup bounds invented rather than taken from Android (schema max 3 vs 5, 5 000 vs 50 000 items, 2 000 000 vs 1 000 000 KDF iterations) | High | **Fixed.** Constants and messages now come from the Android implementation. The old values would have made an archive importable on one platform and rejected on the other, and permitted twice Android's KDF ceiling. |
| 11b | A deep link could name a host, alert, share, or session the app does not have | Medium | **Fixed.** `parseLaunchLink` accepts only the two published `omniterm://` shapes and `validateLaunchRequest` drops unknown ids. |
| 11c | A notification tap acting before the app lock is satisfied | High | **Fixed.** `LaunchRequestQueue.drain` holds every request while settings are loading or the lock is engaged, and `clear()` discards pending privileged actions — Android's `drainPendingExternalLaunches` rule. |
| 12 | A crafted backup with a downgraded KDF cost or an unbounded host list | Medium | **Fixed.** `validateBackup` bounds schema version, host count, and KDF iterations at both ends. |
| 13 | A failed import leaving the destination half-written | High | **Fixed.** `applyImport` builds and validates the merged list before returning it; the caller writes once. |
| 14 | Secrets migrating between devices inside a backup | High | **By design, prevented.** The interchange records only that a credential existed; the destination must ask for it again. |

## 4. Open items — must be closed before beta

| # | Area | Task |
|---|---|---|
| O1 | SSH library provenance, CVE history, algorithm set, key parsing, and encrypted-key handling | IOS-051 |
| O2 | Keychain accessibility class, `ThisDeviceOnly` enforcement, backup/sync exclusion, behavior on biometric enrolment change | IOS-060 |
| O3 | Database and WAL/SHM file protection class, and whether the database may live in an App Group at all | IOS-042, IOS-065 |
| O4 | Local-network permission prompt and App Transport Security exceptions | IOS-093 |
| O5 | Temporary preview files, share-sheet hand-off, and clipboard residue lifetime | IOS-062 |
| O6 | Notification content under privacy mode on a locked screen, and deep-link validation against real IDs | IOS-063 |
| O7 | Native dependency SBOM and license review for anything the SSH engine pulls in | IOS-005, IOS-051 |
| O8 | Crafted terminal stream fuzzing against the shared emulator on an Apple runtime | IOS-072, IOS-090 |
| O9 | Screenshot/app-switcher redaction while a secret or terminal is on screen | IOS-071 |

## 5. Standing rules confirmed by this review

- No shared code accepts a host key without an explicit user decision, and no adapter may.
- No shared code logs terminal contents, secret values, or secret identifiers.
- Every unsupported platform behavior returns `CapabilityResult.Unsupported`; nothing fakes success.
- Cancellation is part of every asynchronous contract, and cleanup runs even when the caller is gone.
