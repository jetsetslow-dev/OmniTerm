# Public repository security checklist

The repository contains policy and automation, but several protections are GitHub settings and cannot be enabled by a commit. Use this as the maintainer checklist.

## Enforced in the repository

- Actions use least-privilege job/workflow permissions and third-party actions are pinned to full commit SHAs.
- CodeQL scans Java/Kotlin on pushes, pull requests, and weekly; its main-branch run is also the aggregate build/test/lint, migration, release-tooling, and full-history secret-scan gate for automatic prereleases.
- PR checks validate every exported Room schema migration from database version 8 through the current version on an Android emulator.
- Dependency Review rejects newly introduced moderate-or-higher vulnerable dependencies; Dependabot checks Gradle and Actions weekly while keeping major upgrades isolated for review.
- Gradle dependency verification pins artifact and metadata SHA-256 checksums, including release-SBOM tooling; unexpected repository bytes fail the build.
- Gitleaks scans for committed credentials, OpenSSF Scorecard reports supply-chain posture, and Gradle dependency submission keeps GitHub's dependency graph complete.
- Release APK/AAB/SBOM artifacts receive GitHub build-provenance attestations; each release includes a CycloneDX JSON SBOM and checksums.
- Release tags and entries are treated as immutable. GitHub Releases stay drafts until Play accepts the AAB.
- `SECURITY.md`, CODEOWNERS, contribution guidance, and issue/PR templates define the disclosure and review path.

## Configure in GitHub Settings

1. **Security & analysis:** enable Dependency graph, Dependabot alerts, Dependabot security updates, CodeQL/default setup only if it does not duplicate the checked-in advanced workflow, Secret scanning, Push protection, and Private vulnerability reporting. Review bypass requests rather than permanently allowing detected secrets.
2. **Actions:** set the default `GITHUB_TOKEN` permission to read-only; do not allow Actions to create/approve pull requests unless needed. Allow only required actions and reusable workflows. Keep SHA pinning mandatory in review.
3. **Main ruleset:** require pull requests, at least one approval and code-owner review; dismiss stale approvals; require conversation resolution; block force pushes/deletions; require linear history; and require the Build & Test, Dependency review, and CodeQL checks. Include administrators unless an emergency process is documented.
4. **Tag ruleset (`v*`):** prevent updates and deletion. Do not give the release workflow a deletion bypass; retained tags are audit/provenance anchors.
5. **Environments:** require maintainer approval for `production`, restrict it to protected tags/branches, and scope production signing/Play/AdMob secrets there. Keep test-device IDs only in `testing`. Ensure `dry-run` has no production secrets.
6. **Pages:** select GitHub Actions as the Pages source, enforce HTTPS, and protect the `github-pages` environment.
7. **General:** require two-factor authentication for organization members, periodically review collaborators/deploy keys/webhooks/GitHub Apps, and keep branch/tag rules plus environment reviewers under two-person review where possible.

## Operational review

Review CodeQL, Dependabot, Gitleaks, Scorecard, secret-scanning, and dependency-graph alerts at least weekly. Rotate signing or service credentials immediately after suspected disclosure. Before each production promotion, verify the source SHA, workflow attestation, checksums, Play versionCode, immutable release state, and test-track install.

Signing material/passwords and AdMob IDs are stored in both `testing` and `production`; the stable debug key is scoped to a `debug` environment restricted to `main`, and the workflow independently checks out `main`. Remove repository-level duplicates only after the first environment-backed release succeeds. GitHub does not expose existing secret values, so `GOOGLE_PLAY_SERVICE_ACCOUNT_JSON` must be re-entered into both release environments before its repository-level copy can be removed. Historical release mappings and duplicate build artifacts also require a controlled one-time retention cleanup; ordinary public Actions artifacts are not private storage.

Before making the Gitleaks history scan required, rotate any credential-like values that ever appeared in copied infrastructure fixtures and decide whether to rewrite public history. Rewriting cannot undo prior exposure. Add historical fingerprints to an ignore file only after rotation is independently confirmed; never path-ignore the synthetic fixture directory.

The release SBOM captures the resolved `playStoreReleaseRuntimeClasspath` dependency graph and is validated before publication. It is attested against the exact signed AAB. Dependency submission separately keeps GitHub's dependency graph current; provenance, an artifact-linked SBOM, and repository dependency submission are complementary controls rather than substitutes.
