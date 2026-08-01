# ADR 0002: iOS portability product decisions

- Status: Accepted
- Date: 2026-08-01
- Owner: Project owner

## Context

The iOS port needs explicit decisions about UI ownership, network-protocol parity, and truthful
background behavior. Implementation agents must not infer or repeatedly reopen these decisions.

## Decision

### Shared UI

Use Compose Multiplatform for Android and iOS UI. Keep platform composition roots and adapters,
but implement reusable screens, navigation state, design tokens, progress/error/empty components,
terminal input policy, and accessibility semantics in shared code where the APIs are supported.

The existing Android UI migrates incrementally. No task may replace a proven Android screen with an
incomplete shared screen merely to increase the shared-code percentage. Platform views remain
allowed for behavior that cannot meet performance or accessibility requirements in shared Compose.

### Initial network protocols

The first iOS parity target includes SSH, SFTP, and WebDAV. SMB and FTP are deferred. Android keeps
its existing protocols. The iOS UI must identify deferred protocols as unsupported rather than
pretending an operation succeeded or silently hiding configured data.

Adding SMB or FTP to iOS requires a follow-up ADR covering maintained libraries, authentication,
transport security, cancellation, large transfers, path traversal, licensing, and SBOM ownership.

### Background terminal behavior

`tmux` is the persistence boundary. iOS may keep a connection during the short execution time the
system naturally grants after backgrounding, but OmniTerm will not declare unrelated background
modes or promise an indefinite socket. A persistent session detaches or loses transport safely and
reconnects to its `tmux` session on foreground. A non-tmux session must warn that backgrounding may
disconnect it.

Monitoring and alert data shown after suspension is explicitly cached or stale until a foreground
refresh succeeds. Continuous remote monitoring requires a separately designed server/push service;
it is not emulated by abusing iOS background APIs.

### Compose reconsideration

Compose Multiplatform is the selected UI strategy, not a post-milestone experiment. Reconsideration
requires measured evidence of an unsolved accessibility, platform-integration, build, or rendering
problem and a replacement ADR approved by the project owner.

## Consequences

- Shared code may depend on multiplatform Compose libraries, but platform objects remain outside
  common state and domain contracts.
- CI needs both Android and macOS gates.
- SSH/SFTP and terminal rendering remain the main technical spikes even with shared UI.
- Product copy and tests must describe iOS suspension honestly.
- Protocol configuration models must represent unsupported capabilities explicitly.
