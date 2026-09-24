# Kotlin dependency update — temporary tracker

Updated: 2026-09-24. Scope: Dependabot #107 and its metadata companion #108.

AGP is updated to 9.4.1 and the app resolves Bouncy Castle 1.86. The previous
resolution rule forced the provider to 1.85.2 despite the catalog bump. App and
project-tool configurations now use the catalog baseline for the provider and its
companion modules. Existing vulnerable-version substitution matches are retained.
AGP's separate plugin classpath still resolves its upstream Bouncy Castle 1.80.2;
that tooling graph is not the dependency packaged in the app.

The original PR failed strict verification of the new AGP plugin marker. Fresh
metadata was regenerated from the existing trusted metadata using
`./scripts/refresh-verification-metadata.sh --write`, followed by the full gate's
independent `--verify`. Both passed forced resolution of buildscript, app variants,
tests, lint, benchmark, compilation and both release SBOM graphs. Metadata review:
95 expected new artifacts, paired SHA-256/SHA-512 hashes, no removed artifacts and
no changed existing hashes. Resolved runtime graphs and the release SBOM confirm
Bouncy Castle 1.86. The metadata companion has not been merged or called green.

`./scripts/local-pr-check.sh --full` passed on Linux x86_64. Both app variants
executed 570 JVM tests successfully, with two pre-existing disabled tmux replay
cases each; no ARM64 exclusions applied. Native lint passed. API 35 instrumentation
discovered 58 cases: 24 passed (including the Room matrix), 34 opted-out E2E
assumptions, zero actual failures. API 29 remains a required hosted gate.

Separate API 35 repository-fixture provisioning and host-key trust each passed one
case. `E2eAppSurfaceStressTest` passed one case with zero skips using
`-e omniterm_e2e_surfaces yes` and `-e omniterm_e2e_sftp_home /home/<fixture-user>`.
The Docker runtime fixture uses that home; an initial invocation with `/config`
failed before the argument was corrected. This was a fixture setup error, not a
production change. Gradle removes its installed test APKs afterward, so both APKs
were installed once before driving the separate instrumentation invocations.

Pinned all-ref and staged secret scans passed, as did both diff checks. Every
artifact and hash in #108 is present unchanged; the fresh full-graph refresh adds
six further artifacts.

Pending: signed checkpoint and all exact-head hosted checks. No main merge or
release is complete. Before an authorized main merge, consolidate these notes into
the private handover and remove this temporary file.
