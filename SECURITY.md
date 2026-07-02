# Security Policy

## Reporting a vulnerability

Please **do not open a public issue** for security problems.

Use GitHub's private vulnerability reporting instead:
**[Report a vulnerability](https://github.com/jetsetslow-dev/OmniTerm/security/advisories/new)** —
this opens a private advisory that only the maintainer can see.

You can expect an initial response within a few days. Please include steps to
reproduce, the app version (Settings → About → Device & diagnostics), and the
Android version you tested on.

## Supported versions

Only the latest release on the [Releases page](https://github.com/jetsetslow-dev/OmniTerm/releases)
and the latest Google Play build receive security fixes.

## Scope notes

- OmniTerm stores SSH keys, credential profiles and share passwords on-device;
  backups containing sensitive sections are AES-256-GCM encrypted with a
  passphrase-derived key.
- Reports about connecting to hosts/shares you do not own or administer are out
  of scope.
