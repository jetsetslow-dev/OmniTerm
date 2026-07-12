# Release runbook

OmniTerm uses packed SemVer as the only version source of truth:

```text
versionName = MAJOR.MINOR.PATCH[-SUFFIX]
versionCode = MAJOR*10,000,000 + MINOR*100,000 + PATCH*100 + BUILD
```

Prereleases use build slots 1–98 (the suffix's trailing number, or 1); the suffix-free production release uses slot 99. For example, `v1.2.3-rc.2` is `10200302` and `v1.2.3` is `10200399`. Limits are major ≤ 200, minor ≤ 99, patch ≤ 999.

The public Git history was intentionally reset after `v0.9.239` to remove credential-bearing infrastructure fixtures. The release resolver retains `v0.9.239` only as a logical Play versionCode baseline when no release tags exist; old commits, tags, and release entries are not provenance inputs for the fresh repository.

## Normal flow

1. Merge or push a tested commit to `main`. The aggregate CodeQL workflow builds, tests, and lints both flavors; only its successful completion starts the automatic prerelease. Its tag is deterministic for that SHA (for example `v1.2.3-main.1`), so rerunning the workflow does not allocate a new version.
2. Confirm the Android build/tests, provenance attestation, internal Play upload, and GitHub prerelease all succeeded.
3. From a clean local `main` exactly equal to `origin/main`, run:

   ```bash
   ./scripts/release.sh
   ```

   The script requires a fully published prerelease for the same SHA and base version, then promotes it to the suffix-free build-99 tag. It pushes only the tag and never pushes `main`, which prevents duplicate branch-plus-tag release races.
4. Verify the internal Play release and install the source-available APK. Promote to wider Play tracks in Play Console only after smoke testing.

For an explicit version use `./scripts/release.sh --tag vMAJOR.MINOR.PATCH[-SUFFIX]`. For an additional prerelease line use `./scripts/release.sh --prerelease rc.2`. The helper refuses non-increasing versions and existing tags.

## Publication transaction and retries

CI creates or updates a GitHub **draft**, uploads the AAB and matching R8 mapping directly to Play, then a separate finalization job publishes the GitHub Release. A Play failure therefore leaves a draft and never presents the APK as successfully shipped. If only finalization fails, use **Rerun failed jobs** so the Play upload is not repeated. A rerun after full success sees the published release marker and skips the external uploads.

No distributed workflow can infer whether Play accepted an upload if the runner dies before receiving or recording the API response. In that rare state, inspect Play Console for the resolved `versionCode` before retrying the release job. If it exists, finalize the matching draft without uploading again; otherwise rerun. Never guess or use a second tag with an aliased versionCode.

Do not delete or move release tags or their GitHub Releases. They are immutable audit records, and the published-versus-draft state is what makes old workflow reruns safe and idempotent.

## Dry runs and break glass

- Manual dispatch with `publish_artifacts=false` builds and tests with throwaway signing material; it does not publish.
- `version_code` is only for recovery after an out-of-band Play Console upload. It bypasses the monotonicity guard, so compare against Play's highest used code first and record the reason.
- If a legacy workflow published GitHub before Play failed, the published marker is not proof of Play upload. Check Play Console before rerunning or use a new strictly higher version.

## Required environments and secrets

Use `testing`, `production`, and `dry-run` GitHub Environments. Store the signing/password, AdMob, Play service account, and stable debug-keystore secrets only in the environments/jobs that need them. Leave `ADMOB_TEST_DEVICE_IDS` unset in production. Protect the production environment with a maintainer approval and restrict deployment branches/tags.

Repository settings that must be configured outside Git are listed in [REPOSITORY_SECURITY.md](REPOSITORY_SECURITY.md).
