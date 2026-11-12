# Contributing to OmniTerm

Contributions are welcome under the GPL-3.0. For a security vulnerability, do not open an issue; follow [SECURITY.md](SECURITY.md).

By contributing you agree that your contribution is licensed under the GPL-3.0 and that the project owner may also license it under other terms.

## Development workflow

1. Branch from `main` using a descriptive name such as `fix/terminal-resize` or `feature/ssh-option`.
2. Keep changes focused and add regression tests for behavior changes.
3. Run the smallest relevant tests, then the repository gate before requesting review:

   ```bash
   ./scripts/test-release-version.sh
   ./gradlew testOpenSourceDebugUnitTest testPlayStoreDebugUnitTest --no-daemon
   ./gradlew assembleDebug --no-daemon
   ./gradlew lintOpenSourceDebug lintPlayStoreDebug --no-daemon
   ```

4. Open a pull request explaining the user-visible behavior, risks, test evidence, and screenshots for UI changes.

Pull requests must pass build/tests, lint, dependency review, secret guards, and CodeQL where applicable. Do not commit credentials, keystores, service-account JSON, production ad IDs, host inventories, or captured terminal output containing secrets. Use synthetic fixtures rather than sanitized copies of deployed infrastructure.

## Terminal changes

Terminal behavior is stateful and timing-sensitive. Include tests for chunk boundaries, malformed/truncated input, resize during alternate-screen use, reconnect/close races, UTF-8, and tmux control-mode framing as relevant. Update the [compatibility matrix](docs/TERMINAL_COMPATIBILITY.md) when support changes.

## Releases (maintainers)

Do not edit `versionCode`, push `main` and a release tag together, or move an existing release tag. Packed SemVer and the automated prerelease/production flow are documented in the [release runbook](docs/RELEASE_RUNBOOK.md). Use `scripts/release.sh` for a production tag after the `main` prerelease succeeds.
