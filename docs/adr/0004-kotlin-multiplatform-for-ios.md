# ADR 0004: Reach iOS with Kotlin Multiplatform, not Flutter

- Status: accepted
- Date: 2026-11-08

## Context

OmniTerm shipped as a native Kotlin Android app. A Flutter rewrite (PR #92, `migration-to-flutter`)
was started to add iOS, but it never shipped: the Kotlin app is the only one that went live, and
every new feature had to be written twice to keep the two in step.

## Decision

- The Flutter migration is cancelled. PR #92 is closed and its branch kept as the signed tag
  `archive/flutter-migration`.
- OmniTerm stays one Kotlin codebase. iOS comes through Kotlin Multiplatform: logic in a `shared`
  module first, then the UI through Compose Multiplatform.
- Android and iOS stay in sync in features and behaviour. Platform code is limited to small
  adapters, plus the pieces each platform requires to be native, such as widgets and Shortcuts.
  Where Apple does not allow a feature, the iOS app says so to the user instead of hiding it.
- The Java-only network engines (JSch, smbj, commons-net) move to one Go library built for both
  platforms, behind the existing `SshTransport` interface. It becomes the default only once it
  passes the same device suites as JSch.

## Consequences

- New features land in Kotlin once and reach both platforms as they move into `shared`.
- `shared/commonMain` must stay free of `java.*` and `android.*`; Kotlin/Native compilation on
  every gate run catches a slip.
- iOS builds and tests need macOS, so they run on GitHub's macOS runners; Linux can still compile
  the iOS code.
- The shipped Android app's dependencies do not change until screens move to Compose
  Multiplatform.
