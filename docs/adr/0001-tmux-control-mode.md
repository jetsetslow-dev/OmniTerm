# ADR 0001: Keep tmux control mode optional

- Status: accepted, experimental
- Date: 2026-07-10

## Context

A normal `tmux attach` renders terminal escape sequences and survives disconnects, but recovering complete history after a reconnect requires capture/replay and careful deduplication. tmux control mode (`tmux -C`), also used by iTerm2's integration, emits structured pane output and command replies. It improves lossless output handling but adds a second stateful protocol, version variance, pane identity, command framing, and recovery failure modes.

## Decision

Keep the normal tmux attach path as the default. Offer control mode as an explicit experimental setting. Parse the control channel separately from terminal bytes, validate pane IDs, hex-encode input, serialize commands, bound queues, and fall back/fail visibly rather than interpreting protocol lines as terminal output.

## Consequences

The stable path remains available on older or unusual tmux installations. Control mode can evolve behind tests based on captured real protocol fixtures. Until multiple tmux versions and reconnect/resync cases are exercised in CI or an integration harness, documentation and UI must not describe it as full iTerm2 feature parity.
