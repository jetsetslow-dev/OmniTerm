# Open-source programme readiness

Read on 2026-11-12 from the official pages named below. Judged against OmniTerm as it will be after this branch merges: GPL-3.0. Programme terms can change at any time; re-read the pages before applying.

## Anthropic: Claude for Open Source

Sources: https://claude.com/open-source-max (criteria and benefit) and
https://www.anthropic.com/claude-for-oss-terms (full terms). The pages name the benefit as six
months of Claude Ultra (some third-party articles say Max 20x; the official pages are authoritative).

| Criterion (terms s.2) | OmniTerm today | Met |
|---|---|---|
| Maintainer track, any one: 500+ dependent repos or 100+ dependent packages; 200,000+ monthly registry downloads; listed committer on a recognised foundation or language project; 100+ PRs merged into repos you do not own in 12 months; 20+ unique external contributors with merged PRs in 12 months; OpenSSF criticality score 0.4+ | Repository has 1 star, 0 forks, 1 human contributor, no package published to a registry (GitHub API, 2026-11-12). No foundation role | No |
| Ecosystem Impact track (discretionary): project the ecosystem "meaningfully depends on", with a written explanation | An end-user Android app, not a dependency of other projects | Unlikely |
| Natural person, 18+, eligible region | Applicant-specific | Unknown |
| GitHub account in good standing, at least two years old | `jetsetslow-dev` was created 2026-06-12 (about 5 months) | No, unless another account of the applicant is older |
| Public open-source activity within the last 90 days | Last push 2026-11-09; many commits | Yes |
| At least one project under an OSI-approved licence (MIT, Apache 2.0, BSD and GPL are the named examples) | GPL-3.0 (OSI-approved; GPL is a named example) | Yes (after merge; PolyForm Noncommercial, the current licence on `main`, would not qualify) |
| Not an Anthropic employee, contractor or family member | Applicant-specific | Unknown |

Terms also say activity judged trivial or automated may be discounted and that decisions are final.
The criteria pages say nothing about a project that also sells a build or has a paid tier.

## OpenAI: Codex for Open Source

Sources: https://developers.openai.com/codex/community/codex-for-oss and
https://learn.chatgpt.com/docs/codex-for-oss-terms (the terms URL on developers.openai.com
redirects there). A separate Codex Open Source Fund (API credits) is described on the first page.

| Criterion | OmniTerm today | Met |
|---|---|---|
| "Core maintainer or run a widely used public project"; others may apply by explaining an "important role in the ecosystem" | Sole maintainer of an active public project; usage is very small | Maintainer yes; widely used no |
| Valid ChatGPT account; accurate information about repositories and role | Applicant-specific | Unknown |
| Weighed: repository usage, ecosystem importance, active maintenance, role/permissions | Active and maintained; low usage and ecosystem importance | Partly |
| Codex Security: repositories the applicant owns or administers | Applicant owns the repository | Yes |
| API-credit fund: projects using Codex in PR review, maintainer automation, release workflows | AGENTS.md and AI_FIRST_DEVELOPMENT.md document AI-assisted development, CI and release automation | Plausible |
| Licence | No licence requirement is stated on either page | Not stated; GPL-3.0 is open source |

No star, download or dependent threshold is published. The pages say nothing about projects that
sell a build or have a paid tier.

## Gaps and honest assessment

OmniTerm does not meet any quantitative Anthropic maintainer-track criterion today and the
account-age rule fails for `jetsetslow-dev`. OpenAI's programme is discretionary with no numeric
bar, so an application is reasonable but not assured. Building adoption (releases, stars, external
contributors and merged outside PRs), tagging a first GPL-3.0 release, enabling Discussions
content and publishing the site would strengthen any application.

## Licence

The chosen licence is GPL-3.0, which is OSI-approved and meets Anthropic's OSI-licence criterion.
