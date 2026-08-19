# mill

A software factory: an orchestrator that drives Claude Code through a fixed software
development pipeline. Feed it a feature or bugfix spec, get a pull request.

You design interactively, in a normal terminal session where human judgment is worth the
most. mill does everything after that — planning, adversarial review, implementation,
review again — and opens a PR for you to read. It never merges; reading the PR is the one
human gate on the output, and the point.

Work arrives as GitHub activity: an issue with a spec on a linked branch, a comment on a
PR, a red CI check. A GitHub Project board is the queue. One Ruby process on your own
machine runs the whole thing.

**Status: design phase.** The documents are the project so far; implementation is next.

## Where to start

- [The design doc](docs/superpowers/specs/2026-08-06-software-factory-design.md) — the
  architecture, the stage graph, containment, the failure taxonomy, and why it's shaped
  this way. Five revisions in, two adversarial reviews survived.
- [The SDLC, beat by beat](docs/superpowers/specs/2026-08-18-sdlc-beats.md) — every step
  of every stage, and which existing agent skill each practice was extracted from.
- [The spec standard](docs/reference/spec-standard.md) — what a spec must contain before
  an unattended pipeline can build from it without stopping to ask questions.

## Reference

- [Domain vocabulary and operational reference](docs/reference/mill.md)
- [Setup runbook](docs/reference/setup.md) — the board, the tokens, branch protection

## Stack

Ruby, Roda, Sequel, SQLite, Puma, Minitest, vanilla JS, stdlib for nearly everything else.
