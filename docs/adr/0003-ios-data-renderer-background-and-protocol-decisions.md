# ADR 0003: iOS data layer, terminal renderer, background grace, and protocol parity

- Status: Accepted
- Date: 2026-08-02
- Owner: Project owner
- Supersedes: the "Initial network protocols" section of ADR 0002

## Context

ADR 0002 settled UI strategy, an initial protocol set, and truthful background behavior. Four
questions remained open and were blocking implementation: where iOS persistence lives, whether the
terminal renderer follows ADR 0002's shared-UI default or IOS-072's native recommendation, what
exactly happens to a session when iOS backgrounds the app, and whether iOS ships the full Android
protocol set.

## Decision

### Data layer: Room stays Android-only

Room, its entities, DAOs, and its migration matrix stay in the Android application. iOS gets its own
persistence implementation behind the shared repository contracts.

Rationale: the Android migration matrix is valuable and proven, and a KMP move would put existing
user data at risk for parity that the repository contracts already provide. The cost is accepted
knowingly: two schema implementations must be kept in step, and the encrypted backup format
(IOS-092) is the only bridge between them, so its field-level compatibility tests become required
rather than advisory.

Consequences:

- IOS-041 is closed as "will not do" in its original form. IOS-042 covers only the iOS store's own
  location, protection class, and migrations.
- Every repository contract in `commonMain` must be satisfiable by both implementations, so no
  contract may expose Room types, cursors, or SQL.
- Schema drift is a release risk: any column added on one platform must be added to the other or
  explicitly recorded as platform-only in the backup schema.

### Terminal renderer: native UIKit/CoreText

The iOS terminal is a native `UIView` renderer using CoreText, not a shared Compose canvas. ADR 0002
already permits platform views where shared Compose cannot meet performance or accessibility
requirements; the terminal is the clearest such case (glyph metrics, large scrollback, IME, and
selection).

The renderer is written in Kotlin/Native against UIKit and CoreText so it compiles in the existing
`:shared` Apple targets, keeps the emulator and snapshot model shared, and needs no separate Swift
build. Terminal emulation, snapshots, input policy, and viewport logic stay in `commonMain`.

Consequences:

- The renderer cannot be validated on Linux beyond compilation; it needs the Xcode gate before any
  rendering, performance, or accessibility claim.
- Non-terminal iOS screens continue to follow ADR 0002's Compose Multiplatform default.

### Background behavior: detach after a short grace period

On entering the background, a persistent (tmux) session starts a grace timer of 20–30 seconds. If
the app is still backgrounded when it expires, OmniTerm detaches the tmux session cleanly and closes
the local SSH connection; the remote session and anything running in it survive and are resumable.
Returning to the foreground before expiry keeps the connection.

A non-tmux session is told, before backgrounding, that it may be disconnected; it is never presented
as if it survives.

Consequences:

- No unrelated background mode is declared, and App Store review notes describe exactly this.
- The grace period is a product constant, not a guarantee: iOS may suspend sooner, and the
  reconnect path must handle that identically.

### Protocol parity: SMB, FTP, and WebDAV on iOS

iOS targets full parity with Android's protocol set. This supersedes ADR 0002's deferral of SMB and
FTP.

Consequences and required follow-up, per ADR 0002's own condition on adding these protocols:

- WebDAV is already shared (Ktor) and needs only the Darwin engine already configured.
- FTP and SMB each require a maintained implementation for Apple targets, with its own licensing,
  SBOM ownership, and dependency-verification entries before any code depends on it.
- Each protocol needs TLS/authentication, cancellation, large-transfer, path-traversal, and
  malformed-server tests before it may be enabled in a build.
- Until an implementation exists and passes those tests, the protocol must present an explicit
  unsupported state. A configured share whose protocol is unavailable is shown as unavailable — it
  is never hidden, and an operation on it never reports success.

## Status of work

- Data layer, renderer, and background grace are implementable now.
- Protocol parity is accepted as the target; SMB in particular has no maintained Kotlin/Native
  implementation today, so the honest path is contracts plus explicit unsupported states until a
  library is selected in a follow-up ADR.
