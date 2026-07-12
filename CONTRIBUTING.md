# Contributing to OmniTerm

Contributions are welcome under the repository's PolyForm Noncommercial license. For a security vulnerability, do not open an issue; follow [SECURITY.md](SECURITY.md).

By submitting a contribution, you represent that you have the right to submit it and agree that it is licensed under the same terms as the repository (inbound equals outbound). The project does not currently require a CLA or DCO sign-off. A future relicensing policy would require an explicit, separately reviewed contributor-rights process; accepting a contribution today does not silently grant additional relicensing rights.

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
