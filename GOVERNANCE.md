# Governance

OmniTerm is currently maintained by `jetsetslow-dev`, who is responsible for roadmap decisions, releases, security response, repository administration, and the final review of contributions.

Technical decisions should be discussed in issues or pull requests with the user impact, alternatives, security implications, compatibility cost, and test evidence made explicit. Maintainers may decline changes that broaden permissions, weaken at-most-once remote-operation guarantees, expose secrets, break supported Android versions, or create an ongoing maintenance burden disproportionate to user value.

Routine changes use pull-request review and required automated checks. Security-sensitive repository settings, production environment secrets, signing material, release-tag rules, and Play publication should use two-person review when a second trusted maintainer is available. Until then, the release runbook and immutable audit artifacts provide the compensating control, and self-approval must not be represented as independent review.

Project policies may evolve in public commits. Material licensing or contributor-rights changes require explicit notice and do not retroactively alter rights already granted.
