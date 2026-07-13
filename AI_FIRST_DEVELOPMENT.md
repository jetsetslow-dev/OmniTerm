# AI-First Development

OmniTerm is developed AI-first: maintainers use AI throughout discovery,
design, implementation, testing, review, documentation, security analysis, and
release preparation. AI is the default force multiplier, while accountable
humans retain ownership of every change and release.

AI-first does not mean AI-only or unreviewed automation. The same engineering,
security, privacy, licensing, and quality standards apply regardless of how a
change was produced.

## Working policy

- Use AI early to explore alternatives, identify edge cases, generate focused
  implementations, and expand tests and documentation.
- Treat AI output as untrusted until it has been reviewed against repository
  context and verified by proportionate tests, static analysis, and security
  checks.
- Require human approval for releases and for changes affecting credentials,
  cryptography, authentication, authorization, data deletion, privacy, signing,
  payments, or repository security controls.
- Never submit secrets, personal data, private keys, proprietary third-party
  code, or other restricted material to an AI service.
- Prefer original implementations, standard platform APIs, and properly
  licensed dependencies. Keep dependency notices current in
  `THIRD_PARTY_NOTICES.md`.
- Review generated changes for correctness, race conditions, error handling,
  accessibility, performance, security, privacy, and license compliance.
- Keep changes traceable through normal commits, pull requests, reviews, and CI.
  Do not use AI involvement to bypass branch protection or required checks.
- Independently verify factual claims and security-sensitive recommendations;
  do not treat model confidence as evidence.
- Contributors remain responsible for code they submit and should disclose
  material AI use when it helps reviewers assess provenance or risk.

## Accountability

The project license and dependency licenses control use of the code; using AI
does not create a separate license exception. Maintainers remain responsible
for accepting contributions, resolving incidents, and approving production
releases.
