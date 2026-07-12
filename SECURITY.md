# Security Policy

## Reporting a vulnerability

Please **do not open a public issue** for security problems.

Use GitHub's private vulnerability reporting instead:
**[Report a vulnerability](https://github.com/jetsetslow-dev/OmniTerm/security/advisories/new)** —
this opens a private advisory that only the maintainer can see.

You can expect an acknowledgement within three business days and an initial
severity/impact assessment within seven business days. Remediation timing depends
on complexity and user risk; we aim to coordinate disclosure within 90 days unless
active exploitation or ecosystem coordination requires a different timeline. Include steps to
reproduce, the app version (Settings → About → Device & diagnostics), and the
Android version you tested on.

Please also include the affected feature/protocol, impact, prerequisites, and a
minimal proof of concept with credentials and host details removed. We will
coordinate remediation and disclosure through the private advisory.

If private vulnerability reporting is unavailable, contact the maintainer through
the private contact method listed on the `jetsetslow-dev` GitHub profile and include
only enough detail to establish a secure follow-up channel. Never send live credentials,
private keys, backup files, or an unredacted host inventory.

## Supported versions

Only the latest release on the [Releases page](https://github.com/jetsetslow-dev/OmniTerm/releases)
and the latest Google Play build receive security fixes.

## Scope notes

- OmniTerm stores SSH keys, credential profiles and share passwords on-device;
  backups containing sensitive sections are AES-256-GCM encrypted with a
  passphrase-derived key.
- Reports about connecting to hosts/shares you do not own or administer are out
  of scope.
- Good-faith research that avoids privacy violations, data destruction, service
  disruption, and access beyond what is needed to demonstrate the issue will not
  be pursued by the project. This is not authorization to test third-party systems.
- Do not access other users' data, persist on a system, degrade availability, or
  test against infrastructure you do not own or have explicit permission to assess.
- We ask researchers to allow a reasonable remediation window and avoid public
  disclosure while a coordinated fix is in progress.
